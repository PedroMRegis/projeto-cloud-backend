"""Política de preço e desconto.

Código puro: não conhece AWS nem HTTP. O LLM nunca define preço — ele apenas
pede um desconto, e o teto é calculado aqui a partir dos dados do catálogo
(PLANO §5.2, "Política de negociação").
"""

from __future__ import annotations

from dataclasses import dataclass

# Teto de desconto: 5% a partir de 3 itens; 10% a partir de 5 itens
# ou quando o subtotal passa de R$ 300,00.
DISCOUNT_TIER_SMALL_PCT = 5
DISCOUNT_TIER_LARGE_PCT = 10
DISCOUNT_MIN_ITEMS_SMALL = 3
DISCOUNT_MIN_ITEMS_LARGE = 5
DISCOUNT_LARGE_SUBTOTAL_CENTS = 300_00

MAX_QTY_PER_ITEM = 10


@dataclass(frozen=True)
class QuoteItem:
    product_id: str
    quantity: int
    unit_price_cents: int

    @property
    def subtotal_cents(self) -> int:
        return self.unit_price_cents * self.quantity


@dataclass(frozen=True)
class Quote:
    items: tuple[QuoteItem, ...]
    subtotal_cents: int
    discount_pct: int
    discount_cents: int
    total_cents: int
    max_discount_pct: int
    discount_was_capped: bool


def total_quantity(items: tuple[QuoteItem, ...]) -> int:
    return sum(item.quantity for item in items)


def max_discount_pct(items: tuple[QuoteItem, ...]) -> int:
    """Teto de desconto permitido para um conjunto de itens."""
    qty = total_quantity(items)
    subtotal = sum(item.subtotal_cents for item in items)

    if qty >= DISCOUNT_MIN_ITEMS_LARGE or subtotal > DISCOUNT_LARGE_SUBTOTAL_CENTS:
        return DISCOUNT_TIER_LARGE_PCT
    if qty >= DISCOUNT_MIN_ITEMS_SMALL:
        return DISCOUNT_TIER_SMALL_PCT
    return 0


def build_quote(items: tuple[QuoteItem, ...], requested_discount_pct: int = 0) -> Quote:
    """Monta a cotação aplicando o teto de desconto.

    Um desconto acima do permitido é limitado ao teto (nunca rejeitado), e
    `discount_was_capped` sinaliza isso para que a resposta informe o usuário.
    """
    if not items:
        raise ValueError("cotação precisa de pelo menos um item")
    for item in items:
        if item.quantity < 1 or item.quantity > MAX_QTY_PER_ITEM:
            raise ValueError(
                f"quantidade inválida para {item.product_id}: {item.quantity} "
                f"(permitido 1..{MAX_QTY_PER_ITEM})"
            )
        if item.unit_price_cents < 0:
            raise ValueError(f"preço inválido para {item.product_id}")

    subtotal = sum(item.subtotal_cents for item in items)
    ceiling = max_discount_pct(items)
    requested = max(0, int(requested_discount_pct))
    applied = min(requested, ceiling)

    # Arredondamento para baixo: nunca conceder mais desconto que o devido.
    discount_cents = subtotal * applied // 100

    return Quote(
        items=items,
        subtotal_cents=subtotal,
        discount_pct=applied,
        discount_cents=discount_cents,
        total_cents=subtotal - discount_cents,
        max_discount_pct=ceiling,
        discount_was_capped=requested > ceiling,
    )
