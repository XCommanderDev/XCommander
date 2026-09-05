// Types for Xcode's index store, and function-pointer typedefs for the entry points we use.
//
// Deliberately declares **no functions**, only their pointer types. libIndexStore.dylib
// lives inside Xcode and its path moves with the user's Xcode install, so linking against
// it would make the whole app fail to launch when Xcode moves or is missing. Everything is
// resolved with dlsym at runtime instead, and an unavailable library costs us the symbol
// picker rather than the product.
#ifndef INDEXSTORE_SHIM_H
#define INDEXSTORE_SHIM_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef void *indexstore_t;
typedef void *indexstore_unit_reader_t;
typedef void *indexstore_record_reader_t;
typedef void *indexstore_symbol_t;
typedef void *indexstore_occurrence_t;
typedef void *indexstore_unit_dependency_t;
typedef void *indexstore_error_t;

typedef struct {
    const char *data;
    size_t length;
} indexstore_string_ref_t;

typedef bool (*indexstore_unit_applier_t)(void *context, indexstore_string_ref_t unit_name);
typedef bool (*indexstore_dependency_applier_t)(void *context, indexstore_unit_dependency_t dep);
typedef bool (*indexstore_occurrence_applier_t)(void *context, indexstore_occurrence_t occ);

typedef indexstore_t (*fn_store_create)(const char *path, indexstore_error_t *error);
typedef void (*fn_store_dispose)(indexstore_t store);
typedef const char *(*fn_error_get_description)(indexstore_error_t error);
typedef bool (*fn_store_units_apply)(indexstore_t store, unsigned sorted, void *context,
                                     indexstore_unit_applier_t applier);
typedef indexstore_unit_reader_t (*fn_unit_reader_create)(indexstore_t store, const char *name,
                                                          indexstore_error_t *error);
typedef void (*fn_unit_reader_dispose)(indexstore_unit_reader_t reader);
typedef bool (*fn_unit_deps_apply)(indexstore_unit_reader_t reader, void *context,
                                   indexstore_dependency_applier_t applier);
typedef unsigned (*fn_dependency_get_kind)(indexstore_unit_dependency_t dep);
typedef indexstore_string_ref_t (*fn_dependency_get_name)(indexstore_unit_dependency_t dep);
typedef indexstore_string_ref_t (*fn_dependency_get_filepath)(indexstore_unit_dependency_t dep);
typedef indexstore_record_reader_t (*fn_record_reader_create)(indexstore_t store, const char *name,
                                                              indexstore_error_t *error);
typedef void (*fn_record_reader_dispose)(indexstore_record_reader_t reader);
typedef bool (*fn_record_occurrences_apply)(indexstore_record_reader_t reader, void *context,
                                            indexstore_occurrence_applier_t applier);
typedef indexstore_symbol_t (*fn_occurrence_get_symbol)(indexstore_occurrence_t occ);
typedef uint64_t (*fn_occurrence_get_roles)(indexstore_occurrence_t occ);
typedef void (*fn_occurrence_get_line_col)(indexstore_occurrence_t occ, unsigned *line, unsigned *col);
typedef unsigned (*fn_symbol_get_kind)(indexstore_symbol_t symbol);
typedef indexstore_string_ref_t (*fn_symbol_get_name)(indexstore_symbol_t symbol);

#endif
