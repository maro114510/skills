test_remove_1_removing_one_pen_leaves_two_units() {
  cart_remove SHARED_CART pen 1
  cart_count SHARED_CART
  assert_eq 2 "${REPLY}"
}

test_remove_2_removing_the_last_pen_empties_the_pen_line() {
  cart_remove SHARED_CART pen 1
  cart_count SHARED_CART
  assert_eq 1 "${REPLY}"
}
