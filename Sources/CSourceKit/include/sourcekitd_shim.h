// Types for sourcekitd, and function-pointer typedefs for the entry points we use.
//
// Same discipline as `indexstore_shim.h`: **no functions are declared**, only their pointer
// types. `sourcekitdInProc.framework` lives inside whichever Xcode is selected, so linking
// against it would make the app fail to launch whenever Xcode moves, is missing, or is a
// different version. Everything is resolved with dlsym at runtime, and an unavailable
// sourcekitd costs the preview's colouring rather than the product.
//
// The reason this header exists at all, where the index store's could have been avoided:
// `sourcekitd_variant_t` is a 24-byte struct passed and returned **by value**, and Swift
// will not put a Swift struct through `@convention(c)`. Declaring it in C makes it C
// representable, and the calls become ordinary.
#ifndef SOURCEKITD_SHIM_H
#define SOURCEKITD_SHIM_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef void *sourcekitd_object_t;
typedef void *sourcekitd_response_t;
typedef void *sourcekitd_uid_t;

// Three 64-bit words, by value. The first is a pointer to the variant's type functions;
// the rest are its payload. We never read the fields — only hand it back to the API.
typedef struct {
    uint64_t data[3];
} sourcekitd_variant_t;

typedef enum {
    SOURCEKITD_VARIANT_TYPE_NULL = 0,
    SOURCEKITD_VARIANT_TYPE_DICTIONARY = 1,
    SOURCEKITD_VARIANT_TYPE_ARRAY = 2,
    SOURCEKITD_VARIANT_TYPE_INT64 = 3,
    SOURCEKITD_VARIANT_TYPE_STRING = 4,
    SOURCEKITD_VARIANT_TYPE_UID = 5,
    SOURCEKITD_VARIANT_TYPE_BOOL = 6,
    SOURCEKITD_VARIANT_TYPE_DOUBLE = 7,
    SOURCEKITD_VARIANT_TYPE_DATA = 8,
} sourcekitd_variant_type_t;

typedef void (*sk_initialize_t)(void);
typedef void (*sk_shutdown_t)(void);

typedef sourcekitd_object_t (*sk_request_create_from_yaml_t)(const char *yaml, char **error);
typedef void (*sk_request_release_t)(sourcekitd_object_t object);
typedef sourcekitd_response_t (*sk_send_request_sync_t)(sourcekitd_object_t request);

typedef bool (*sk_response_is_error_t)(sourcekitd_response_t response);
typedef void (*sk_response_dispose_t)(sourcekitd_response_t response);
typedef sourcekitd_variant_t (*sk_response_get_value_t)(sourcekitd_response_t response);

typedef sourcekitd_uid_t (*sk_uid_get_from_cstr_t)(const char *string);
typedef const char *(*sk_uid_get_string_ptr_t)(sourcekitd_uid_t uid);

typedef sourcekitd_variant_type_t (*sk_variant_get_type_t)(sourcekitd_variant_t value);
typedef sourcekitd_variant_t (*sk_variant_dictionary_get_value_t)(sourcekitd_variant_t dict,
                                                                 sourcekitd_uid_t key);
typedef sourcekitd_uid_t (*sk_variant_dictionary_get_uid_t)(sourcekitd_variant_t dict,
                                                           sourcekitd_uid_t key);
typedef int64_t (*sk_variant_dictionary_get_int64_t)(sourcekitd_variant_t dict,
                                                     sourcekitd_uid_t key);
typedef const char *(*sk_variant_dictionary_get_string_t)(sourcekitd_variant_t dict,
                                                          sourcekitd_uid_t key);
typedef size_t (*sk_variant_array_get_count_t)(sourcekitd_variant_t array);
typedef sourcekitd_variant_t (*sk_variant_array_get_value_t)(sourcekitd_variant_t array,
                                                             size_t index);

#endif
