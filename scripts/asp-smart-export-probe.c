// Experimental, read-only ASP static-statistics capability probe.
//
// This is a standalone verification tool. It does not run sysdiagnose and is
// not linked into NenRing. The two options accepted here are the
// fixed options observed in the macOS 25G83 sysdiagnose_helper path:
//
//   option 7: ASP export/band-statistics fallback
//   option 8: ASP NAND-defects path
//
// The interface and vtable offsets are private, build-specific observations,
// not a public macOS ABI. No option scanning is performed. One option is run
// per process, with a hard process alarm and an explicit private output root.
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
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
    kASPExportOption = 7,
    kASPNANDDefectsOption = 8,
    kMaximumOutputBytes = 1024 * 1024,
    kProbeTimeoutSeconds = 15,
    kProbeVersion = 2
};

// Vtable offsets observed in sysdiagnose_helper's IO NVMe Smart extraction.
enum {
    kASPExportVTableOffset = 0xa8,
    kASPNANDDefectsVTableOffset = 0xc8
};

typedef struct {
    void *bytes;
    uint32_t capacity;
    uint32_t responseBytes;
    kern_return_t result;
    uint64_t elapsedNanoseconds;
} StaticRead;

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

static int parseOption(const char *value, uint32_t *option) {
    char *end = NULL;
    unsigned long parsed;

    if (value == NULL || option == NULL || value[0] == '\0') {
        return 0;
    }
    errno = 0;
    parsed = strtoul(value, &end, 0);
    if (errno != 0 || end == value || *end != '\0') {
        return 0;
    }
    if (parsed != kASPExportOption && parsed != kASPNANDDefectsOption) {
        return 0;
    }
    *option = (uint32_t)parsed;
    return 1;
}

static void printUsage(const char *program) {
    fprintf(stderr,
        "Usage: %s --option 7|8 [--output-dir DIRECTORY]\n"
        "  --option      one fixed 25G83 helper option; no option scan\n"
        "  --output-dir  retain raw bytes in a new mode-0700 run directory\n",
        program
    );
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
    int success;

    if (descriptor < 0) {
        return 0;
    }
    success = writeAll(descriptor, bytes, length);
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
    uint32_t option,
    char *runDirectory,
    size_t runDirectoryLength
) {
    time_t now = time(NULL);
    int written = snprintf(
        runDirectory,
        runDirectoryLength,
        "%s/25G83-smart-option-%u-%lld-%d",
        root,
        option,
        (long long)now,
        (int)getpid()
    );
    if (written <= 0 || (size_t)written >= runDirectoryLength) {
        return 0;
    }
    return mkdir(runDirectory, 0700) == 0;
}

static CFUUIDRef privatePluginUUID(void) {
    return CFUUIDGetConstantUUIDWithBytes(
        NULL,
        0xaa, 0x0f, 0xa6, 0xf9, 0xc2, 0xd6, 0x45, 0x7f,
        0xb1, 0x0b, 0x59, 0xa1, 0x32, 0x53, 0x29, 0x2f
    );
}

static CFUUIDRef privateSmartInterfaceUUID(void) {
    return CFUUIDGetConstantUUIDWithBytes(
        NULL,
        0xcc, 0xd1, 0xdb, 0x19, 0xfd, 0x9a, 0x4d, 0xaf,
        0xbf, 0x95, 0x12, 0x45, 0x4b, 0x23, 0x0a, 0xb6
    );
}

static int openPrivateSmartInterface(
    IOCFPlugInInterface ***pluginOut,
    void **smartInterfaceOut,
    io_service_t *serviceOut
) {
    CFMutableDictionaryRef matching;
    io_iterator_t iterator = IO_OBJECT_NULL;
    io_service_t service = IO_OBJECT_NULL;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t result;
    HRESULT queryResult;
    void *smartInterface = NULL;

    if (pluginOut == NULL || smartInterfaceOut == NULL || serviceOut == NULL) {
        return 0;
    }
    *pluginOut = NULL;
    *smartInterfaceOut = NULL;
    *serviceOut = IO_OBJECT_NULL;

    matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFMutableDictionaryRef propertyMatch = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (matching == NULL || propertyMatch == NULL) {
        if (propertyMatch != NULL) {
            CFRelease(propertyMatch);
        }
        if (matching != NULL) {
            CFRelease(matching);
        }
        return 0;
    }
    CFDictionarySetValue(propertyMatch, CFSTR("NVMe SMART Capable"), kCFBooleanTrue);
    CFDictionarySetValue(matching, CFSTR("IOPropertyMatch"), propertyMatch);
    CFRelease(propertyMatch);
    result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    );
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "matching_result=0x%08x (%s)\n", result, mach_error_string(result));
        return 0;
    }

    service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "matching_result=success service_count=0\n");
        return 0;
    }

    result = IOCreatePlugInInterfaceForService(
        service,
        privatePluginUUID(),
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    if (result != KERN_SUCCESS || plugin == NULL) {
        fprintf(stderr, "plugin_result=0x%08x (%s) score=%d\n", result, mach_error_string(result), (int)score);
        IOObjectRelease(service);
        return 0;
    }

    queryResult = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(privateSmartInterfaceUUID()),
        &smartInterface
    );
    if (queryResult != S_OK || smartInterface == NULL) {
        fprintf(stderr, "query_result=0x%08x interface=%p\n", (unsigned int)queryResult, smartInterface);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(service);
        return 0;
    }

    *pluginOut = plugin;
    *smartInterfaceOut = smartInterface;
    *serviceOut = service;
    return 1;
}

static void closePrivateSmartInterface(
    IOCFPlugInInterface **plugin,
    void *smartInterface,
    io_service_t service
) {
    if (smartInterface != NULL) {
        void ***object = (void ***)smartInterface;
        void (*release)(void *) = (void (*)(void *))(*object)[3];
        if (release != NULL) {
            release(smartInterface);
        }
    }
    if (plugin != NULL) {
        IODestroyPlugInInterface(plugin);
    }
    if (service != IO_OBJECT_NULL) {
        IOObjectRelease(service);
    }
}

static StaticRead fetchStaticStatistics(void *smartInterface, uint32_t option) {
    StaticRead read = {0};
    uint8_t *bytes;
    uint32_t (*method)(void *, void *, uint32_t *);
    void ***object = (void ***)smartInterface;
    size_t vtableOffset;
    uint64_t started;

    if (option == kASPExportOption) {
        vtableOffset = kASPExportVTableOffset;
    } else {
        vtableOffset = kASPNANDDefectsVTableOffset;
    }
    bytes = (uint8_t *)calloc(1, kMaximumOutputBytes);
    if (bytes == NULL) {
        read.result = KERN_RESOURCE_SHORTAGE;
        return read;
    }

    read.bytes = bytes;
    read.capacity = kMaximumOutputBytes;
    read.responseBytes = kMaximumOutputBytes;
    method = (uint32_t (*)(void *, void *, uint32_t *))(*object)[vtableOffset / sizeof(void *)];
    if (method == NULL) {
        read.result = KERN_INVALID_ARGUMENT;
        return read;
    }
    started = monotonicNanoseconds();
    read.result = (kern_return_t)method(smartInterface, bytes, &read.responseBytes);
    read.elapsedNanoseconds = monotonicNanoseconds() - started;
    if (read.responseBytes > read.capacity) {
        read.responseBytes = 0;
    }
    return read;
}

static int writeArtifacts(
    const char *runDirectory,
    uint32_t option,
    const char *build,
    uid_t effectiveUser,
    time_t capturedAt,
    const StaticRead *read,
    double totalElapsedMilliseconds
) {
    char binaryPath[PATH_MAX];
    char metadataPath[PATH_MAX];
    char metadata[2048];
    int written;
    size_t responseBytes;

    if (snprintf(binaryPath, sizeof(binaryPath), "%s/option-%u.bin", runDirectory, option) <= 0 ||
        snprintf(metadataPath, sizeof(metadataPath), "%s/metadata.txt", runDirectory) <= 0) {
        return 0;
    }
    responseBytes = read->result == KERN_SUCCESS ? read->responseBytes : 0;
    if (responseBytes > 0 &&
        !writeExclusive(binaryPath, read->bytes, responseBytes)) {
        return 0;
    }
    written = snprintf(
        metadata,
        sizeof(metadata),
        "build=%s\n"
        "contractBuild=25G83\n"
        "probeVersion=%u\n"
        "service=GetNVMeSMARTInterface\n"
        "plugin_uuid=AA0FA6F9-C2D6-457F-B10B-59A13253292F\n"
        "interface_uuid=CCD1DB19-FD9A-4DAF-BF95-12454B230AB6\n"
        "option=%u\n"
        "vtable_offset=0x%zx\n"
        "role=%s\n"
        "euid=%u\n"
        "captured_at_epoch=%lld\n"
        "result=0x%08x\n"
        "response_bytes=%zu\n"
        "capacity_bytes=%u\n"
        "elapsed_ms=%.3f\n"
        "total_elapsed_ms=%.3f\n"
        "format_status=unconfirmed\n",
        build != NULL ? build : "unknown",
        kProbeVersion,
        option,
        option == kASPExportOption ? (size_t)kASPExportVTableOffset : (size_t)kASPNANDDefectsVTableOffset,
        option == kASPExportOption ? "ASP export/band statistics" : "ASP NAND defects",
        (unsigned int)effectiveUser,
        (long long)(capturedAt > 0 ? capturedAt : 0),
        (unsigned int)read->result,
        responseBytes,
        read->capacity,
        elapsedMilliseconds(0, read->elapsedNanoseconds),
        totalElapsedMilliseconds
    );
    if (written <= 0 || (size_t)written >= sizeof(metadata) ||
        !writeExclusive(metadataPath, metadata, (size_t)written)) {
        if (responseBytes > 0) {
            unlink(binaryPath);
        }
        return 0;
    }
    printf("artifact_dir=%s\n", runDirectory);
    printf("artifact_payload=%s\n", responseBytes > 0 ? binaryPath : "none");
    printf("artifact_metadata=%s\n", metadataPath);
    return 1;
}

int main(int argc, char **argv) {
    const char *outputRoot = NULL;
    uint32_t option = 0;
    char build[64] = {0};
    size_t buildSize = sizeof(build);
    char runDirectory[PATH_MAX] = {0};
    IOCFPlugInInterface **plugin = NULL;
    void *smartInterface = NULL;
    io_service_t service = IO_OBJECT_NULL;
    StaticRead read;
    uint64_t totalStarted;
    uint64_t totalFinished;
    time_t capturedAt;
    int success;

    for (int index = 1; index < argc; index += 1) {
        if (strcmp(argv[index], "--option") == 0 && index + 1 < argc) {
            if (!parseOption(argv[++index], &option)) {
                fprintf(stderr, "Unsupported option. Use 7 or 8.\n");
                return 2;
            }
        } else if (strcmp(argv[index], "--output-dir") == 0 && index + 1 < argc) {
            outputRoot = argv[++index];
        } else if (strcmp(argv[index], "--help") == 0) {
            printUsage(argv[0]);
            return 0;
        } else {
            printUsage(argv[0]);
            return 2;
        }
    }
    if (option == 0) {
        printUsage(argv[0]);
        return 2;
    }
    if (sysctlbyname("kern.osversion", build, &buildSize, NULL, 0) != 0) {
        snprintf(build, sizeof(build), "unknown");
    }
    if (outputRoot != NULL && !ensurePrivateDirectory(outputRoot)) {
        fprintf(stderr, "Output directory must be an existing or new private directory (mode 700): %s\n", outputRoot);
        return 2;
    }
    if (outputRoot != NULL && !makeRunDirectory(outputRoot, option, runDirectory, sizeof(runDirectory))) {
        fprintf(stderr, "Unable to create a new private run directory below: %s\n", outputRoot);
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGALRM, expired);
    alarm(kProbeTimeoutSeconds);
    totalStarted = monotonicNanoseconds();
    capturedAt = time(NULL);
    printf("build=%s euid=%u option=%u\n", build, (unsigned int)geteuid(), option);
    if (!openPrivateSmartInterface(&plugin, &smartInterface, &service)) {
        puts("smart_interface=not_found_or_query_failed");
        alarm(0);
        return 3;
    }
    puts("smart_interface=open");
    read = fetchStaticStatistics(smartInterface, option);
    totalFinished = monotonicNanoseconds();
    printf(
        "static_read=0x%08x (%s) response_bytes=%u capacity=%u elapsed_ms=%.3f\n",
        (unsigned int)read.result,
        mach_error_string(read.result),
        read.responseBytes,
        read.capacity,
        elapsedMilliseconds(0, read.elapsedNanoseconds)
    );
    success = read.result == KERN_SUCCESS && read.responseBytes > 0;
    if (outputRoot != NULL) {
        if (!writeArtifacts(
            runDirectory,
            option,
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
    closePrivateSmartInterface(plugin, smartInterface, service);
    alarm(0);
    return success ? 0 : 7;
}
