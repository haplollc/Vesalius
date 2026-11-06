#ifndef VESALIUS_GRAMMARS_H
#define VESALIUS_GRAMMARS_H

typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_python(void);

const TSLanguage *tree_sitter_php(void);
const TSLanguage *tree_sitter_php_only(void);
const TSLanguage *tree_sitter_c_sharp(void);

#endif
