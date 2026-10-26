test_remove_without_a_quantity_drops_the_whole_line() {
  local cart=""
  cart_add cart pen 2
  cart_remove cart pen
  cart_count cart
  assert_eq 0 "${REPLY}"
}

test_remove_with_a_quantity_drops_only_those_units() {
  local cart=""
  cart_add cart pen 3
  cart_remove cart pen 1
  cart_count cart
  assert_eq 2 "${REPLY}"
}

test_removing_more_than_the_cart_holds_fails_with_3_and_keeps_the_line() {
  local cart=""
  cart_add cart pen 1
  assert_status 3 cart_remove cart pen 2
  cart_count cart
  assert_eq 1 "${REPLY}"
}

test_removing_an_unknown_sku_fails_with_2() {
  # shellcheck disable=SC2034 # cart_remove reads it through its name
  local cart=""
  assert_status 2 cart_remove cart pen
}
