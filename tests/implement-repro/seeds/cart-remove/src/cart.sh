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

# Returns 2 for a sku that is not in the cart, and 3 for a quantity that is not positive or exceeds the line.
# Without a quantity the whole line goes. The cart is unchanged on a failure.
cart_remove() { # cart sku [quantity]
  local out="" word have="" want="${3-}"
  for word in ${!1-}; do
    if [[ "${word%%=*}" == "$2" ]]; then
      have="${word#*=}"
    fi
  done
  [[ -n "${have}" ]] || return 2
  [[ -n "${want}" ]] || want="${have}"
  [[ "${want}" -gt 0 && "${want}" -le "${have}" ]] || return 3
  for word in ${!1-}; do
    if [[ "${word%%=*}" != "$2" ]]; then
      out="${out} ${word}"
    elif [[ "${want}" -lt "${have}" ]]; then
      out="${out} $2=$((have - want))"
    fi
  done
  printf -v "$1" %s "${out# }"
}
