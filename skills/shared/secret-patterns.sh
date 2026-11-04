# shellcheck shell=bash
# Secret patterns shared across skills, so every scanner reads one list instead of keeping a copy.
# Sourcing it only defines variables; babysit's gate.sh reads them.
# shellcheck disable=SC2034 # The sourcing script reads them.

# Path patterns, matched in lower case
RE_SECRETFILE='(^|/)\.env(\..+)?$|(^|/)\.netrc$|(^|/)\.git-credentials$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)credentials(\.json)?$|\.(pem|key|p12|pfx|jks|keystore|kdbx)$|(^|/)secrets?\.(ya?ml|json|toml|env)$'
RE_SECRETFILE_OK='\.env\.(example|sample|template|dist)$'

# Line patterns for grep -E; RE_ASSIGN and RE_ASSIGN_BARE are matched with -i
dq='"'
sq="'"
bt='`'
quote="[${dq}${sq}${bt}]"
RE_KEYHDR='-----BEGIN [A-Z ]*PRIVATE KEY'
RE_TOKEN='(^|[^[:alnum:]])(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|[sr]k_live_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
RE_ASSIGN="(key|token|secret|passw(or)?d|credentials?)[A-Za-z0-9_]*${quote}?[[:space:]]*(:=|=|:)[[:space:]]*${quote}[^${dq}${sq}${bt}\$[:space:]{<(][^${dq}${sq}${bt}]{5,}${quote}"
# An unquoted literal that ends the line or a # comment, with punctuation allowed. A reference, a call, a bracketed value, and prose after the value do not match.
RE_ASSIGN_BARE='(key|token|secret|passw(or)?d|credentials?)[A-Za-z0-9_]*[[:space:]]*(:=|=|:)[[:space:]]*[A-Za-z0-9+/_.~@!#%^&*?|:,-][A-Za-z0-9+/_.=~@!#%^&*?|:,-]{7,};?[[:space:]]*(#.*)?$'
