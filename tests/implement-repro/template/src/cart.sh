# A cart is a variable holding "sku=quantity" words, and every function takes the variable's name first.
# A function returns its result in REPLY.
# shellcheck disable=SC2086 # the cart's words are split on purpose

cart_add() { # cart sku quantity
  [[ "$3" -gt 0 ]] || return 1
  local out="" word found=""
  for word in ${!1-}; do
    if [[ "${word%%=*}" == "$2" ]]; then
      word="$2=$((${word#*=} + $3))"
      found=1
    fi
    out="${out} ${word}"
  done
  [[ -n "${found}" ]] || out="${out} $2=$3"
  printf -v "$1" %s "${out# }"
}

cart_count() { # cart
  local word n=0
  for word in ${!1-}; do
    n=$((n + ${word#*=}))
  done
  REPLY="${n}"
}
