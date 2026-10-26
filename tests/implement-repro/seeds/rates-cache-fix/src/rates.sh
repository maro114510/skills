# Exchange rates in hundredths of the base currency, read through a per-process cache.
# A function returns its result in REPLY, because a result printed to $(...) would be cached in a subshell.
# shellcheck disable=SC2034 # the rate and cache variables are read through indirect expansion

rates_reset() {
  RATE_USD=100 RATE_EUR=125 RATE_GBP=150
  unset CACHE_USD CACHE_EUR CACHE_GBP
}

rates_set() { # code rate
  [[ "$2" -gt 0 ]] || return 1
  printf -v "RATE_$1" %s "$2"
  unset "CACHE_$1"
}

rates_get() { # code
  local cache="CACHE_$1" rate="RATE_$1"
  if [[ -z "${!cache-}" ]]; then
    [[ -n "${!rate-}" ]] || return 1
    printf -v "${cache}" %s "${!rate}"
  fi
  REPLY="${!cache}"
}

rates_convert() { # amount code
  rates_get "$2" || return 1
  REPLY=$(($1 * REPLY / 100))
}
