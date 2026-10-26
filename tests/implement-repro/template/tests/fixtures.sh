# shellcheck disable=SC2034 # read by the test files

# Built once and reused by every cart test to keep them short.
SHARED_CART=""
cart_add SHARED_CART pen 2
cart_add SHARED_CART ink 1
