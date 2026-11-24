// Experimental, read-only ASP FTL-statistics probe.
//
// This is a standalone verification tool for the macOS 25G83 private
// GetNVMeSMARTInterface path. It does not run sysdiagnose and does not scan
// vtable methods. The two accepted kinds correspond to the fixed methods used
// by sysdiagnose_helper:
//
//   all  -> vtable offset 0x108
//   perm -> vtable offset 0x110
//
// The returned buffer is intentionally kept as an unconfirmed artifact. The
// format, counter units, and record timestamps must be checked against the
// helper's parser before any value is connected to the application.
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
    kMaximumOutputBytes = 1024 * 1024,
    kProbeTimeoutSeconds = 15,
    kProbeVersion = 3,
    kAllVTableOffset = 0x108,
    kPermanentVTableOffset = 0x110
};

typedef struct {
    void *bytes;
    uint32_t capacity;
    uint32_t responseBytes;
    kern_return_t result;
    uint64_t elapsedNanoseconds;
} StatsRead;

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

static int parseKind(const char *value, int *kind) {
    if (value == NULL || kind == NULL) {
        return 0;
    }
    if (strcmp(value, "all") == 0) {
        *kind = 0;
        return 1;
    }
    if (strcmp(value, "perm") == 0) {
        *kind = 1;
        return 1;
    }
    return 0;
}

// Darwin majors (the leading number of the build, e.g. 26 in "26A434") of
// the macOS releases whose FTL interface was reviewed: 25 = macOS 26,
// 26 = macOS 27. Keep in sync with
// DirectFTLContractRegistry.reviewedMacOSMajorVersions
// (DirectFTLContractRegistryTests enforces this).
static const int kReviewedDarwinMajors[] = { 25, 26, 0 };

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
        "Usage: %s --kind all|perm [--output-dir DIRECTORY] [--allow-unreviewed-build]\n"
        "         [--smart-service-id ID --controller-id ID --whole-media-id ID]\n"
        "  --kind        one fixed ASP FTL-statistics method (25G83 key contract)\n"
        "  --output-dir  retain raw bytes in a new mode-0700 run directory\n"
        "  --owner-uid   restore a root-created run directory to this user\n"
        "  --owner-gid   restore a root-created run directory to this group\n"
        "  --allow-unreviewed-build\n"
        "                call the private interface on a macOS release that has\n"
        "                not been reviewed (results are unverified)\n",
        program
    );
}

static int parseUnsignedID(const char *value, uint64_t *parsed) {
    char *end = NULL;
    unsigned long long candidate;

    if (value == NULL || parsed == NULL || value[0] == '\0') {
        return 0;
    }
    errno = 0;
    candidate = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || candidate > UINT_MAX) {
        return 0;
    }
    *parsed = (uint64_t)candidate;
    return 1;
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

static int parseRegistryID(const char *value, uint64_t *parsed) {
    char *end = NULL;
    if (value == NULL || value[0] == '\0') { return 0; }
    for (const char *cursor = value; *cursor != '\0'; cursor += 1) {
        if (*cursor < '0' || *cursor > '9') { return 0; }
    }
    errno = 0;
    unsigned long long number = strtoull(value, &end, 10);
    if (errno != 0 || *end != '\0' || number == 0) { return 0; }
    *parsed = (uint64_t)number;
    return 1;
}

static int isSynthesizedMedia(io_registry_entry_t entry, io_registry_entry_t service) {
    IOObjectRetain(entry);
    for (int depth = 0; depth < 64 && entry != IO_OBJECT_NULL; depth += 1) {
        io_name_t className = {0};
        io_registry_entry_t parent = IO_OBJECT_NULL;
        IOObjectGetClass(entry, className);
        if (strncmp(className, "AppleAPFS", 9) == 0 || strncmp(className, "AppleRAID", 9) == 0) {
            IOObjectRelease(entry);
            return 1;
        }
        if (entry == service) { IOObjectRelease(entry); return 0; }
        IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry);
        entry = parent;
    }
    if (entry != IO_OBJECT_NULL) { IOObjectRelease(entry); }
    return 1;
}

static int hasSingleWholeMedia(io_registry_entry_t service, uint64_t expectedMediaID) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) { return 0; }
    unsigned int visited = 0;
    unsigned int whole = 0;
    uint64_t mediaID = 0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        visited += 1;
        if (IOObjectConformsTo(entry, "IOMedia")) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("Whole"), kCFAllocatorDefault, 0);
            if (value != NULL) {
                if (CFEqual(value, kCFBooleanTrue) && !isSynthesizedMedia(entry, service)) {
                    whole += 1;
                    IORegistryEntryGetRegistryEntryID(entry, &mediaID);
                }
                CFRelease(value);
            }
        }
        IOObjectRelease(entry);
        if (visited > 256 || whole > 1) { IOObjectRelease(iterator); return 0; }
    }
    // The registry changed while walking it, so the count may be incomplete.
    if (!IOIteratorIsValid(iterator)) { IOObjectRelease(iterator); return 0; }
    IOObjectRelease(iterator);
    return whole == 1 && (expectedMediaID == 0 || mediaID == expectedMediaID);
}

// Every artifact is created relative to an already-opened directory with
// O_NOFOLLOW, so a path swapped for a symlink while the probe runs as root
// cannot redirect the write or the ownership change.
static int writeExclusiveAt(
    int directory,
    const char *name,
    const void *bytes,
    size_t length,
    int restoreOwner,
    uid_t ownerUID,
    gid_t ownerGID
) {
    int descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int success;

    if (descriptor < 0) {
        return 0;
    }
    success = writeAll(descriptor, bytes, length);
    if (success && restoreOwner && geteuid() == 0 && fchown(descriptor, ownerUID, ownerGID) != 0) {
        success = 0;
    }
    if (close(descriptor) != 0) {
        success = 0;
    }
    if (!success) {
        unlinkat(directory, name, 0);
    }
    return success;
}

// Opens the output root without following a final symlink and checks that
// it is a private directory owned by the expected user. As root, the owner
// must be the user the artifacts are handed back to (or root itself), so a
// redirected path can never make root write into someone else's directory.
static int openPrivateDirectory(const char *path, int restoreOwner, uid_t ownerUID) {
    struct stat status;
    int directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    uid_t expectedOwner = geteuid() == 0 ? (restoreOwner ? ownerUID : 0) : geteuid();

    if (directory < 0 && errno == ENOENT && geteuid() != 0) {
        if (mkdir(path, 0700) != 0) {
            return -1;
        }
        directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    if (directory < 0) {
        return -1;
    }
    if (fstat(directory, &status) != 0 ||
        !S_ISDIR(status.st_mode) ||
        (status.st_mode & 0077) != 0 ||
        status.st_uid != expectedOwner) {
        close(directory);
        return -1;
    }
    return directory;
}

static int makeRunDirectory(
    int rootDirectory,
    const char *rootPath,
    const char *kindName,
    int restoreOwner,
    uid_t ownerUID,
    gid_t ownerGID,
    char *runName,
    size_t runNameLength,
    char *runDirectory,
    size_t runDirectoryLength
) {
    time_t now = time(NULL);
    int directory;
    int written = snprintf(
        runName,
        runNameLength,
        "25G83-asp-ftl-%s-%lld-%d",
        kindName,
        (long long)now,
        (int)getpid()
    );
    if (written <= 0 || (size_t)written >= runNameLength) {
        return -1;
    }
    written = snprintf(runDirectory, runDirectoryLength, "%s/%s", rootPath, runName);
    if (written <= 0 || (size_t)written >= runDirectoryLength) {
        return -1;
    }
    if (mkdirat(rootDirectory, runName, 0700) != 0) {
        return -1;
    }
    directory = openat(rootDirectory, runName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) {
        return -1;
    }
    if (restoreOwner && geteuid() == 0 && fchown(directory, ownerUID, ownerGID) != 0) {
        close(directory);
        return -1;
    }
    return directory;
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

/// True when `service` sits below an Apple ANS NVMe controller. Every
/// reviewed class (AppleANS3NVMeController, AppleANS3CGv2Controller) is a
/// subclass of AppleANS2NVMeController.
static uint64_t appleANSControllerID(io_service_t service) {
    io_registry_entry_t entry = service;
    int depth;
    IOObjectRetain(entry);
    for (depth = 0; depth < 16 && entry != IO_OBJECT_NULL; depth++) {
        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IOObjectConformsTo(entry, "AppleANS2NVMeController")) {
            uint64_t entryID = 0;
            IORegistryEntryGetRegistryEntryID(entry, &entryID);
            IOObjectRelease(entry);
            return entryID;
        }
        if (IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) != KERN_SUCCESS) {
            parent = IO_OBJECT_NULL;
        }
        IOObjectRelease(entry);
        entry = parent;
    }
    if (entry != IO_OBJECT_NULL) {
        IOObjectRelease(entry);
    }
    return 0;
}

static int openPrivateSmartInterface(
    uint64_t requestedServiceID,
    uint64_t requestedControllerID,
    uint64_t requestedMediaID,
    IOCFPlugInInterface ***pluginOut,
    void **smartInterfaceOut,
    io_service_t *serviceOut
) {
    CFMutableDictionaryRef matching = NULL;
    CFMutableDictionaryRef propertyMatch = NULL;
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
    propertyMatch = CFDictionaryCreateMutable(
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

    result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "matching_result=0x%08x (%s)\n", result, mach_error_string(result));
        return 0;
    }
    // The NVMe SMART plug-in is public and also serves third-party NVMe
    // drives (for example over Thunderbolt). The private FTL methods are
    // only reviewed for Apple's embedded controller. Select the app's exact
    // service ID, or fail closed unless standalone discovery is unambiguous.
    {
        io_service_t candidate;
        unsigned int candidates = 0;
        unsigned int matches = 0;
        unsigned int controllerCandidates = 0;
        while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            candidates += 1;
            if (candidates > 64) {
                IOObjectRelease(candidate);
                IOObjectRelease(iterator);
                if (service != IO_OBJECT_NULL) { IOObjectRelease(service); }
                fprintf(stderr, "Too many SMART service candidates.\n");
                return 0;
            }
            uint64_t entryID = 0;
            IORegistryEntryGetRegistryEntryID(candidate, &entryID);
            uint64_t controllerID = appleANSControllerID(candidate);
            if (controllerID != 0 && controllerID == requestedControllerID) { controllerCandidates += 1; }
            if (controllerID != 0 &&
                (requestedServiceID == 0 || requestedServiceID == entryID)) {
                matches += 1;
                if (service == IO_OBJECT_NULL) { service = candidate; }
                else { IOObjectRelease(candidate); }
            } else {
                IOObjectRelease(candidate);
            }
        }
        // The registry changed while matching; the counts may be incomplete.
        if (!IOIteratorIsValid(iterator)) {
            IOObjectRelease(iterator);
            if (service != IO_OBJECT_NULL) { IOObjectRelease(service); }
            fprintf(stderr, "Storage registry changed during matching.\n");
            return 0;
        }
        IOObjectRelease(iterator);
        if (service == IO_OBJECT_NULL || matches != 1 || (requestedControllerID != 0 && controllerCandidates != 1)) {
            if (service != IO_OBJECT_NULL) { IOObjectRelease(service); }
            fprintf(stderr, "matching_result=success service_count=%u apple_ans_matches=%u (requires exactly one)\n", candidates, matches);
            return 0;
        }
        if (!hasSingleWholeMedia(service, requestedMediaID)) {
            IOObjectRelease(service);
            fprintf(stderr, "FTL scope is ambiguous: expected exactly one whole media.\n");
            return 0;
        }
        if (requestedControllerID != 0) {
            io_registry_entry_t entry = service;
            IOObjectRetain(entry);
            int matchedController = 0;
            for (int depth = 0; depth < 64 && entry != IO_OBJECT_NULL; depth += 1) {
                uint64_t entryID = 0;
                io_registry_entry_t parent = IO_OBJECT_NULL;
                IORegistryEntryGetRegistryEntryID(entry, &entryID);
                if (entryID == requestedControllerID && IOObjectConformsTo(entry, "AppleANS2NVMeController")) {
                    matchedController = 1;
                    IOObjectRelease(entry);
                    entry = IO_OBJECT_NULL;
                    break;
                }
                IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
                IOObjectRelease(entry);
                entry = parent;
            }
            if (entry != IO_OBJECT_NULL) { IOObjectRelease(entry); }
            if (!matchedController) {
                IOObjectRelease(service);
                fprintf(stderr, "Selected service/controller binding is stale or mismatched.\n");
                return 0;
            }
        }
    }

    result = IOCreatePlugInInterfaceForService(
        service,
        privatePluginUUID(),
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    if (result != KERN_SUCCESS || plugin == NULL) {
        fprintf(stderr, "plugin_result=0x%08x (%s) score=%d\n", result, mach_error_string(result), score);
        IOObjectRelease(service);
        return 0;
    }

    queryResult = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(privateSmartInterfaceUUID()),
        (LPVOID *)&smartInterface
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

static StatsRead fetchStats(void *smartInterface, int kind) {
    StatsRead read = {0};
    uint8_t *bytes;
    uint32_t (*method)(void *, void *, void *, uint32_t *);
    void ***object = (void ***)smartInterface;
    size_t vtableOffset = kind == 0 ? kAllVTableOffset : kPermanentVTableOffset;
    uint64_t started;

    bytes = (uint8_t *)calloc(1, kMaximumOutputBytes);
    if (bytes == NULL) {
        read.result = KERN_RESOURCE_SHORTAGE;
        return read;
    }
    read.bytes = bytes;
    read.capacity = kMaximumOutputBytes;
    read.responseBytes = kMaximumOutputBytes;
    method = (uint32_t (*)(void *, void *, void *, uint32_t *))(*object)[vtableOffset / sizeof(void *)];
    if (method == NULL) {
        read.result = KERN_INVALID_ARGUMENT;
        return read;
    }

    started = monotonicNanoseconds();
    read.result = (kern_return_t)method(smartInterface, bytes, NULL, &read.responseBytes);
    read.elapsedNanoseconds = monotonicNanoseconds() - started;
    if (read.responseBytes > read.capacity) {
        read.responseBytes = 0;
    }
    return read;
}

static int writeArtifacts(
    int runDirectoryFD,
    const char *runDirectory,
    const char *kindName,
    int kind,
    const char *build,
    uid_t effectiveUser,
    time_t capturedAt,
    const StatsRead *read,
    double totalElapsedMilliseconds,
    int restoreOwner,
    uid_t ownerUID,
    gid_t ownerGID,
    uint64_t selectedServiceID,
    uint64_t selectedControllerID,
    uint64_t selectedMediaID
) {
    char binaryName[64];
    char binaryPath[PATH_MAX];
    char metadataPath[PATH_MAX];
    char metadata[2048];
    int written;
    size_t responseBytes = read->result == KERN_SUCCESS ? read->responseBytes : 0;
    size_t vtableOffset = kind == 0 ? kAllVTableOffset : kPermanentVTableOffset;

    if (snprintf(binaryName, sizeof(binaryName), "asp-ftl-%s.bin", kindName) <= 0 ||
        snprintf(binaryPath, sizeof(binaryPath), "%s/%s", runDirectory, binaryName) <= 0 ||
        snprintf(metadataPath, sizeof(metadataPath), "%s/metadata.txt", runDirectory) <= 0) {
        return 0;
    }
    if (responseBytes > 0 &&
        !writeExclusiveAt(runDirectoryFD, binaryName, read->bytes, responseBytes, restoreOwner, ownerUID, ownerGID)) {
        return 0;
    }
    written = snprintf(
        metadata,
        sizeof(metadata),
        "build=%s\n"
        "contractBuild=25G83\n"
        "probeVersion=%u\n"
        "smart_service_entry_id=%llu\n"
        "controller_entry_id=%llu\n"
        "whole_media_entry_id=%llu\n"
        "service=GetNVMeSMARTInterface\n"
        "plugin_uuid=AA0FA6F9-C2D6-457F-B10B-59A13253292F\n"
        "interface_uuid=CCD1DB19-FD9A-4DAF-BF95-12454B230AB6\n"
        "kind=%s\n"
        "vtable_offset=0x%zx\n"
        "input_arg=null\n"
        "role=ASP FTL %s statistics\n"
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
        (unsigned long long)selectedServiceID,
        (unsigned long long)selectedControllerID,
        (unsigned long long)selectedMediaID,
        kindName,
        vtableOffset,
        kindName,
        (unsigned int)effectiveUser,
        (long long)(capturedAt > 0 ? capturedAt : 0),
        (unsigned int)read->result,
        responseBytes,
        read->capacity,
        elapsedMilliseconds(0, read->elapsedNanoseconds),
        totalElapsedMilliseconds
    );
    if (written <= 0 || (size_t)written >= sizeof(metadata) ||
        !writeExclusiveAt(runDirectoryFD, "metadata.txt", metadata, (size_t)written, restoreOwner, ownerUID, ownerGID)) {
        if (responseBytes > 0) {
            unlinkat(runDirectoryFD, binaryName, 0);
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
    const char *kindName = NULL;
    int kind = -1;
    char build[64] = {0};
    size_t buildSize = sizeof(build);
    char runDirectory[PATH_MAX] = {0};
    char runName[128] = {0};
    int rootDirectoryFD = -1;
    int runDirectoryFD = -1;
    IOCFPlugInInterface **plugin = NULL;
    void *smartInterface = NULL;
    io_service_t service = IO_OBJECT_NULL;
    StatsRead read;
    uint64_t totalStarted;
    uint64_t totalFinished;
    time_t capturedAt;
    int success;
    int allowUnreviewedBuild = 0;
    int ownerUIDProvided = 0;
    int ownerGIDProvided = 0;
    uint64_t ownerUIDValue = 0;
    uint64_t ownerGIDValue = 0;
    uint64_t requestedServiceID = 0;
    uint64_t requestedControllerID = 0;
    uint64_t requestedMediaID = 0;

    for (int index = 1; index < argc; index += 1) {
        if (strcmp(argv[index], "--kind") == 0 && index + 1 < argc) {
            kindName = argv[++index];
            if (!parseKind(kindName, &kind)) {
                fprintf(stderr, "Unsupported kind. Use all or perm.\n");
                return 2;
            }
        } else if (strcmp(argv[index], "--allow-unreviewed-build") == 0) {
            allowUnreviewedBuild = 1;
        } else if (strcmp(argv[index], "--smart-service-id") == 0 && index + 1 < argc) {
            if (!parseRegistryID(argv[++index], &requestedServiceID)) { return 2; }
        } else if (strcmp(argv[index], "--controller-id") == 0 && index + 1 < argc) {
            if (!parseRegistryID(argv[++index], &requestedControllerID)) { return 2; }
        } else if (strcmp(argv[index], "--whole-media-id") == 0 && index + 1 < argc) {
            if (!parseRegistryID(argv[++index], &requestedMediaID)) { return 2; }
        } else if (strcmp(argv[index], "--output-dir") == 0 && index + 1 < argc) {
            outputRoot = argv[++index];
        } else if (strcmp(argv[index], "--owner-uid") == 0 && index + 1 < argc) {
            if (!parseUnsignedID(argv[++index], &ownerUIDValue)) {
                fprintf(stderr, "Invalid --owner-uid.\n");
                return 2;
            }
            ownerUIDProvided = 1;
        } else if (strcmp(argv[index], "--owner-gid") == 0 && index + 1 < argc) {
            if (!parseUnsignedID(argv[++index], &ownerGIDValue)) {
                fprintf(stderr, "Invalid --owner-gid.\n");
                return 2;
            }
            ownerGIDProvided = 1;
        } else {
            printUsage(argv[0]);
            return 2;
        }
    }
    if (kind < 0 || kindName == NULL) {
        printUsage(argv[0]);
        return 2;
    }
    if (ownerUIDProvided != ownerGIDProvided) {
        fprintf(stderr, "--owner-uid and --owner-gid must be provided together.\n");
        return 2;
    }
    if ((requestedServiceID == 0) != (requestedControllerID == 0) || (requestedServiceID == 0) != (requestedMediaID == 0)) {
        fprintf(stderr, "Service, controller and whole-media IDs must be provided together.\n");
        return 2;
    }
    if (sysctlbyname("kern.osversion", build, &buildSize, NULL, 0) != 0) {
        snprintf(build, sizeof(build), "unknown");
    }
    // Refuse before opening the private interface: the vtable slots are only
    // known to be the FTL statistics methods on reviewed builds.
    if (!isReviewedBuild(build) && !allowUnreviewedBuild) {
        printf("build=%s reviewed=0\n", build);
        fprintf(stderr, "macOS build %s belongs to a release that is not reviewed. Pass --allow-unreviewed-build to read it anyway.\n", build);
        return 5;
    }
    capturedAt = time(NULL);
    signal(SIGALRM, expired);
    alarm(kProbeTimeoutSeconds);

    totalStarted = monotonicNanoseconds();
    printf("build=%s euid=%u kind=%s\n", build, (unsigned int)geteuid(), kindName);
    if (outputRoot != NULL) {
        rootDirectoryFD = openPrivateDirectory(outputRoot, ownerUIDProvided, (uid_t)ownerUIDValue);
        if (rootDirectoryFD < 0) {
            fprintf(stderr, "Output root must be an existing mode-0700 private directory owned by the artifact owner.\n");
            alarm(0);
            return 2;
        }
    }
    if (!openPrivateSmartInterface(requestedServiceID, requestedControllerID, requestedMediaID, &plugin, &smartInterface, &service)) {
        puts("smart_interface=not_found_or_query_failed");
        alarm(0);
        return 3;
    }
    puts("smart_interface=open");
    read = fetchStats(smartInterface, kind);
    totalFinished = monotonicNanoseconds();
    printf(
        "stats_read=0x%08x (%s) response_bytes=%u capacity=%u elapsed_ms=%.3f\n",
        (unsigned int)read.result,
        mach_error_string(read.result),
        read.responseBytes,
        read.capacity,
        elapsedMilliseconds(0, read.elapsedNanoseconds)
    );
    success = read.result == KERN_SUCCESS && read.responseBytes > 0;
    if (outputRoot != NULL) {
        runDirectoryFD = makeRunDirectory(
            rootDirectoryFD, outputRoot, kindName,
            ownerUIDProvided, (uid_t)ownerUIDValue, (gid_t)ownerGIDValue,
            runName, sizeof(runName), runDirectory, sizeof(runDirectory)
        );
        if (runDirectoryFD < 0 ||
            !writeArtifacts(
                runDirectoryFD,
                runDirectory,
                kindName,
                kind,
                build,
                geteuid(),
                capturedAt,
                &read,
                elapsedMilliseconds(totalStarted, totalFinished),
                ownerUIDProvided,
                (uid_t)ownerUIDValue,
                (gid_t)ownerGIDValue,
                requestedServiceID,
                requestedControllerID,
                requestedMediaID
            )) {
            fprintf(stderr, "Unable to persist private probe artifacts.\n");
            success = 0;
        }
        if (runDirectoryFD >= 0) {
            close(runDirectoryFD);
        }
        close(rootDirectoryFD);
    }
    free(read.bytes);
    closePrivateSmartInterface(plugin, smartInterface, service);
    alarm(0);
    return success ? 0 : 4;
}
