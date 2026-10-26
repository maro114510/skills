test_counts_every_unit_in_the_shared_cart() {
  cart_count SHARED_CART
  assert_eq 3 "${REPLY}"
}

test_adding_to_a_new_cart_counts_its_units() {
  local cart=""
  cart_add cart pen 2
  cart_count cart
  assert_eq 2 "${REPLY}"
}

test_add_rejects_a_zero_quantity() {
  # shellcheck disable=SC2034 # cart_add writes it through its name
  local cart=""
  assert_status 1 cart_add cart pen 0
}
