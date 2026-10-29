// Test-only Security API failures in an owned, ad-hoc agent process.
#include <Security/Security.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool fail(const char *stage) {
    const char *selected = getenv("SWIFTTY_TEST_SIGNING_FAILURE");
    if (selected != NULL && strcmp(selected, stage) == 0) {
        fprintf(stderr, "fixture injected signing failure: %s\n", stage);
        return true;
    }
    return false;
}

static OSStatus copy_self(SecCSFlags flags, SecCodeRef *code) {
    if (fail("self")) return errSecNotAvailable;
    return SecCodeCopySelf(flags, code);
}

static OSStatus validate(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement) {
    if (fail("validity")) return errSecNotAvailable;
    return SecCodeCheckValidity(code, flags, requirement);
}

static OSStatus copy_static(SecCodeRef code, SecCSFlags flags, SecStaticCodeRef *result) {
    if (fail("static")) return errSecNotAvailable;
    return SecCodeCopyStaticCode(code, flags, result);
}

static OSStatus copy_information(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *result) {
    if (fail("information")) return errSecNotAvailable;
    return SecCodeCopySigningInformation(code, flags, result);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_function; const void *old_function; } \
    interpose_##replacement = { (const void *)&replacement, (const void *)&original }

INTERPOSE(copy_self, SecCodeCopySelf);
INTERPOSE(validate, SecCodeCheckValidity);
INTERPOSE(copy_static, SecCodeCopyStaticCode);
INTERPOSE(copy_information, SecCodeCopySigningInformation);
