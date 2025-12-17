// Minimal public header to expose the Swift tree-sitter grammar entrypoint.

#ifndef TREE_SITTER_SWIFT_H_
#define TREE_SITTER_SWIFT_H_

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_swift(void);

#ifdef __cplusplus
}
#endif

#endif  // TREE_SITTER_SWIFT_H_

