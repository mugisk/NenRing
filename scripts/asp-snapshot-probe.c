// Experimental, read-only ASP snapshot capability probe.
//
// This is intentionally a standalone verification tool. It is not linked into
// NenRing and it does not run sysdiagnose. The only commands exposed
// here are the two command IDs observed in the 25G83 sysdiagnose_helper path:
//
//   0x16  ASP snapshot payload used by the helper's time-sensitive path
//   0x91  ASP snapshot header used before the helper formats the payload
//
// The helper's private binary layout is not treated as a public ABI. The probe
// therefore records bytes only when --output-dir is explicitly supplied and
// always records the requested/returned lengths separately from the payload
// length. It never scans selectors/opcodes and never invokes sysdiagnose.
#include <IOKit/IOKitLib.h>
#include <mach/mach_error.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

enum {
    kSnapshotPayloadOpcode = 0x16,
    kSnapshotHeaderOpcode = 0x91,
    kMaximumSnapshotBytes = 16 * 1024 * 1024,
    kProbeTimeoutSeconds = 15,
    kProbeVersion = 3
};

typedef struct {
    uint32_t opcode;
    uint32_t flags;
    uint32_t argument;
    uint32_t reserved[3];
} SnapshotRequest;
_Static_assert(sizeof(SnapshotRequest) == 24, "request ABI");

typedef struct {
    void *bytes;
    uint32_t requestedBytes;
    size_t sizeQueryResponseBytes;
    size_t responseBytes;
    size_t capacityBytes;
    kern_return_t sizeResult;
    kern_return_t readResult;
    int readAttempted;
    uint64_t sizeQueryElapsedNs;
    uint64_t readElapsedNs;
} SnapshotRead;

static void expired(int signalNumber) {
    (void)signalNumber;
    _exit(124);
}

static uint64_t monotonicNanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static double elapsedMilliseconds(uint64_t started, uint64_t finished) {
    if (finished < started) {
        return 0.0;
    }
    return (double)(finished - started) / 1000000.0;
}

static int parseOpcode(const char *value, uint32_t *opcode) {
    char *end = NULL;
    unsigned long parsed;

    if (value == NULL || opcode == NULL || value[0] == '\0') {
        return 0;
    }
    errno = 0;
    parsed = strtoul(value, &end, 0);
    if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
        return 0;
    }
    if (parsed != kSnapshotPayloadOpcode && parsed != kSnapshotHeaderOpcode) {
        return 0;
    }
    *opcode = (uint32_t)parsed;
    return 1;
}

// Darwin majors whose private ANS interface was reviewed. Keep in sync with
// DirectFTLContractRegistry.reviewedMacOSMajorVersions and the FTL probe.
static const int kReviewedDarwinMajors[] = { 25, 26, 0 };

// Class of the matched controller, recorded in the metadata. Matching uses the
// common superclass AppleANS2NVMeController, so AppleANS3NVMeController
// (macOS 26) and AppleANS3CGv2Controller (macOS 27) are both found.
static char gControllerClass[128] = "unknown";

static int isReviewedBuild(const char *build) {
    char *end = NULL;
    long major = strtol(build, &end, 10);
    if (end == build || *end == '\0') {
        return 0;
    }
    for (size_t index = 0; kReviewedDarwinMajors[index] != 0; index += 1) {
        if (major == kReviewedDarwinMajors[index]) {
            return 1;
        }
    }
    return 0;
}

static void printUsage(const char *program) {
    fprintf(stderr,
        "Usage: %s [--opcode 0x16|0x91] [--output-dir DIRECTORY] [--allow-unreviewed-build]\n"
        "  --opcode       one fixed command observed in sysdiagnose_helper (default: 0x16)\n"
        "  --output-dir   explicitly retain raw bytes in a new mode-0700 run directory\n"
        "  --allow-unreviewed-build\n"
        "                 read on a macOS release that has not been reviewed\n",
        program);
}

static int writeAll(int descriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t remaining = length;

    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return 0;
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return 1;
}

static int writeExclusive(const char *path, const void *bytes, size_t length) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        return 0;
    }
    int success = writeAll(descriptor, bytes, length);
    if (close(descriptor) != 0) {
        success = 0;
    }
    if (!success) {
        unlink(path);
    }
    return success;
}

static int ensurePrivateDirectory(const char *path) {
    struct stat status;

    if (stat(path, &status) != 0) {
        if (errno != ENOENT || mkdir(path, 0700) != 0) {
            return 0;
        }
        if (stat(path, &status) != 0) {
            return 0;
        }
    }
    if (!S_ISDIR(status.st_mode) || (status.st_mode & 0077) != 0) {
        return 0;
    }
    if (geteuid() != 0 && status.st_uid != geteuid()) {
        return 0;
    }
    return 1;
}

static int makeRunDirectory(
    const char *root,
    uint32_t opcode,
    char *runDirectory,
    size_t runDirectoryLength
) {
    time_t now = time(NULL);
    int written = snprintf(
        runDirectory,
        runDirectoryLength,
        "%s/25G83-0x%02x-%lld-%d",
        root,
        opcode,
        (long long)now,
        (int)getpid()
    );
    if (written <= 0 || (size_t)written >= runDirectoryLength) {
        return 0;
    }
    return mkdir(runDirectory, 0700) == 0;
}

static int fetchSnapshot(
    io_connect_t connection,
    uint32_t opcode,
    SnapshotRead *read
) {
    size_t responseSize;
    size_t page;
    uint64_t started;
    uint64_t finished;
    SnapshotRequest request = {
        .opcode = opcode,
        .flags = 1,
        .argument = 0,
        .reserved = {0, 0, 0}
    };

    memset(read, 0, sizeof(*read));
    started = monotonicNanoseconds();
    responseSize = sizeof(read->requestedBytes);
    read->sizeResult = IOConnectCallStructMethod(
        connection,
        9,
        &request,
        sizeof(request),
        &read->requestedBytes,
        &responseSize
    );
    finished = monotonicNanoseconds();
    read->sizeQueryElapsedNs = finished >= started ? finished - started : 0;
    read->sizeQueryResponseBytes = responseSize;

    if (read->sizeResult != KERN_SUCCESS ||
        responseSize != sizeof(read->requestedBytes) ||
        read->requestedBytes == 0 ||
        read->requestedBytes > kMaximumSnapshotBytes) {
        return 0;
    }

    page = (size_t)getpagesize();
    if (page == 0 || read->requestedBytes > SIZE_MAX - page + 1) {
        return 0;
    }
    read->capacityBytes = ((size_t)read->requestedBytes + page - 1) / page * page;
    if (posix_memalign(&read->bytes, page, read->capacityBytes) != 0) {
        read->bytes = NULL;
        return 0;
    }
    memset(read->bytes, 0, read->capacityBytes);

    request.flags = 0;
    responseSize = read->capacityBytes;
    read->readAttempted = 1;
    started = monotonicNanoseconds();
    read->readResult = IOConnectCallStructMethod(
        connection,
        9,
        &request,
        sizeof(request),
        read->bytes,
        &responseSize
    );
    finished = monotonicNanoseconds();
    read->readElapsedNs = finished >= started ? finished - started : 0;
    read->responseBytes = responseSize;

    if (read->readResult != KERN_SUCCESS ||
        responseSize == 0 ||
        responseSize > read->capacityBytes) {
        return 0;
    }
    return 1;
}

static int writeRunArtifacts(
    const char *runDirectory,
    uint32_t opcode,
    const char *build,
    uid_t effectiveUser,
    time_t capturedAt,
    const SnapshotRead *read,
    double totalElapsedMilliseconds
) {
    char binaryPath[PATH_MAX];
    char metadataPath[PATH_MAX];
    char metadata[4096];
    int binaryLength;
    int metadataLength;
    size_t payloadBytes = 0;
    const char *role = opcode == kSnapshotPayloadOpcode
        ? "time-sensitive snapshot payload"
        : "snapshot header";

    if (read->bytes != NULL && read->readResult == KERN_SUCCESS) {
        payloadBytes = read->requestedBytes;
        if (payloadBytes > read->responseBytes) {
            payloadBytes = read->responseBytes;
        }
    }
    binaryLength = snprintf(
        binaryPath,
        sizeof(binaryPath),
        "%s/opcode-0x%02x.bin",
        runDirectory,
        opcode
    );
    metadataLength = snprintf(
        metadataPath,
        sizeof(metadataPath),
        "%s/metadata.txt",
        runDirectory
    );
    if (binaryLength <= 0 || (size_t)binaryLength >= sizeof(binaryPath) ||
        metadataLength <= 0 || (size_t)metadataLength >= sizeof(metadataPath)) {
        return 0;
    }
    if (payloadBytes > 0 && !writeExclusive(binaryPath, read->bytes, payloadBytes)) {
        return 0;
    }

    int textLength = snprintf(
        metadata,
        sizeof(metadata),
        "build=%s\n"
        "contractBuild=25G83\n"
        "probeVersion=%u\n"
        "controller=%s\n"
        "selector=9\n"
        "opcode=0x%02x\n"
        "role=%s\n"
        "euid=%u\n"
        "captured_at_epoch=%lld\n"
        "size_query_result=0x%08x\n"
        "size_query_response_bytes=%zu\n"
        "requested_bytes=%u\n"
        "snapshot_read_attempted=%d\n"
        "snapshot_read_result=0x%08x\n"
        "snapshot_read_response_bytes=%zu\n"
        "capacity_bytes=%zu\n"
        "payload_bytes=%zu\n"
        "size_query_elapsed_ms=%.3f\n"
        "snapshot_read_elapsed_ms=%.3f\n"
        "total_elapsed_ms=%.3f\n"
        "format_status=unconfirmed\n",
        build,
        kProbeVersion,
        gControllerClass,
        opcode,
        role,
        (unsigned int)effectiveUser,
        (long long)(capturedAt > 0 ? capturedAt : 0),
        read->sizeResult,
        read->sizeQueryResponseBytes,
        read->requestedBytes,
        read->readAttempted,
        read->readResult,
        read->responseBytes,
        read->capacityBytes,
        payloadBytes,
        elapsedMilliseconds(0, read->sizeQueryElapsedNs),
        elapsedMilliseconds(0, read->readElapsedNs),
        totalElapsedMilliseconds
    );
    if (textLength <= 0 || (size_t)textLength >= sizeof(metadata) ||
        !writeExclusive(metadataPath, metadata, (size_t)textLength)) {
        unlink(binaryPath);
        return 0;
    }
    printf("artifact_dir=%s\n", runDirectory);
    printf("artifact_payload=%s\n", payloadBytes > 0 ? binaryPath : "none");
    printf("artifact_metadata=%s\n", metadataPath);
    return 1;
}

int main(int argc, char **argv) {
    const char *outputRoot = NULL;
    uint32_t opcode = kSnapshotPayloadOpcode;
    char build[64] = {0};
    size_t buildSize = sizeof(build);
    char runDirectory[PATH_MAX] = {0};
    io_service_t service = IO_OBJECT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    SnapshotRead read;
    uint64_t totalStarted;
    uint64_t totalFinished;
    time_t capturedAt;
    kern_return_t result;
    int success;
    int allowUnreviewedBuild = 0;

    for (int index = 1; index < argc; index += 1) {
        if (strcmp(argv[index], "--opcode") == 0 && index + 1 < argc) {
            if (!parseOpcode(argv[++index], &opcode)) {
                fprintf(stderr, "Unsupported opcode. Use 0x16 or 0x91.\n");
                return 2;
            }
        } else if (strcmp(argv[index], "--output-dir") == 0 && index + 1 < argc) {
            outputRoot = argv[++index];
        } else if (strcmp(argv[index], "--allow-unreviewed-build") == 0) {
            allowUnreviewedBuild = 1;
        } else if (strcmp(argv[index], "--help") == 0) {
            printUsage(argv[0]);
            return 0;
        } else {
            printUsage(argv[0]);
            return 2;
        }
    }

    if (sysctlbyname("kern.osversion", build, &buildSize, NULL, 0) != 0) {
        snprintf(build, sizeof(build), "unknown");
    }
    if (!allowUnreviewedBuild && !isReviewedBuild(build)) {
        printf("build=%s reviewed=0\n", build);
        fprintf(stderr, "macOS build %s belongs to a release that is not reviewed. Pass --allow-unreviewed-build to read it anyway.\n", build);
        return 5;
    }
    if (outputRoot != NULL && !ensurePrivateDirectory(outputRoot)) {
        fprintf(stderr, "Output directory must be an existing or new private directory (mode 700): %s\n", outputRoot);
        return 2;
    }
    if (outputRoot != NULL && !makeRunDirectory(outputRoot, opcode, runDirectory, sizeof(runDirectory))) {
        fprintf(stderr, "Unable to create a new private run directory below: %s\n", outputRoot);
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGALRM, expired);
    alarm(kProbeTimeoutSeconds);
    totalStarted = monotonicNanoseconds();
    capturedAt = time(NULL);
    printf("build=%s euid=%u opcode=0x%02x\n", build, (unsigned int)geteuid(), opcode);
    // Open the Apple controller only when it is the only one. With several
    // controllers the first match may not belong to the selected disk, and
    // this research probe takes no target argument.
    {
        io_iterator_t controllers = IO_OBJECT_NULL;
        io_service_t candidate;
        unsigned int controllerCount = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("AppleANS2NVMeController"), &controllers) != KERN_SUCCESS) {
            puts("controller=not_found");
            return 3;
        }
        while ((candidate = IOIteratorNext(controllers)) != IO_OBJECT_NULL) {
            controllerCount++;
            if (service == IO_OBJECT_NULL) {
                service = candidate;
            } else {
                IOObjectRelease(candidate);
            }
        }
        IOObjectRelease(controllers);
        if (controllerCount != 1) {
            if (service != IO_OBJECT_NULL) IOObjectRelease(service);
            if (controllerCount == 0) {
                puts("controller=not_found");
            } else {
                printf("controller=ambiguous count=%u\n", controllerCount);
            }
            return 3;
        }
    }
    if (IOObjectGetClass(service, gControllerClass) != KERN_SUCCESS) {
        snprintf(gControllerClass, sizeof(gControllerClass), "unknown");
    }
    printf("controller=%s\n", gControllerClass);

    result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    printf("open=0x%08x (%s)\n", result, mach_error_string(result));
    if (result != KERN_SUCCESS) {
        return 4;
    }

    success = fetchSnapshot(connection, opcode, &read);
    printf(
        "size_query=0x%08x (%s) response_bytes=%zu snapshot_bytes=%u elapsed_ms=%.3f\n",
        read.sizeResult,
        mach_error_string(read.sizeResult),
        read.sizeQueryResponseBytes,
        read.requestedBytes,
        elapsedMilliseconds(0, read.sizeQueryElapsedNs)
    );
    printf(
        "snapshot_read=0x%08x (%s) response_bytes=%zu capacity=%zu elapsed_ms=%.3f\n",
        read.readResult,
        mach_error_string(read.readResult),
        read.responseBytes,
        read.capacityBytes,
        elapsedMilliseconds(0, read.readElapsedNs)
    );
    totalFinished = monotonicNanoseconds();
    if (outputRoot != NULL) {
        if (!writeRunArtifacts(
            runDirectory,
            opcode,
            build,
            geteuid(),
            capturedAt,
            &read,
            elapsedMilliseconds(totalStarted, totalFinished)
        )) {
            fprintf(stderr, "Unable to persist private probe artifacts.\n");
            success = 0;
        }
    }

    free(read.bytes);
    IOServiceClose(connection);
    alarm(0);
    return success ? 0 : 7;
}
