# Add cart_remove

## Background

Shoppers need to take an item back out of the cart.

## Requirements

- `cart_remove CART SKU [QUANTITY]` removes `QUANTITY` units of `SKU`, or the whole line when `QUANTITY` is omitted.
- A quantity that is not positive, or larger than the cart holds, fails with status 3 and leaves the cart unchanged.
- A sku that is not in the cart fails with status 2.

## Acceptance Criteria

1. `cart_remove cart pen` on a cart holding two pens leaves no pens.
2. `cart_remove cart pen 1` on a cart holding three pens leaves two.
3. `cart_remove cart pen 2` on a cart holding one pen fails with status 3 and the cart still holds one pen.
4. `cart_remove cart pen` on an empty cart fails with status 2.
