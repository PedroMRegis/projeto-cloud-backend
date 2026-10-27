"""Política de desconto — regra de negócio, sem AWS."""

from __future__ import annotations

import pytest

from app.domain.pricing import (
    DISCOUNT_TIER_LARGE_PCT,
    DISCOUNT_TIER_SMALL_PCT,
    QuoteItem,
    build_quote,
    max_discount_pct,
)


def item(product_id: str = "BK001", qty: int = 1, price: int = 1000) -> QuoteItem:
    return QuoteItem(product_id=product_id, quantity=qty, unit_price_cents=price)


class TestTetoDeDesconto:
    def test_carrinho_pequeno_nao_tem_desconto(self) -> None:
        assert max_discount_pct((item(qty=2, price=1000),)) == 0

    def test_tres_itens_liberam_cinco_porcento(self) -> None:
        assert max_discount_pct((item(qty=3, price=1000),)) == DISCOUNT_TIER_SMALL_PCT

    def test_cinco_itens_liberam_dez_porcento(self) -> None:
        assert max_discount_pct((item(qty=5, price=1000),)) == DISCOUNT_TIER_LARGE_PCT

    def test_subtotal_acima_de_300_reais_libera_dez_porcento(self) -> None:
        # Um item caro: quantidade baixa, mas subtotal alto.
        assert max_discount_pct((item(qty=1, price=30_001),)) == DISCOUNT_TIER_LARGE_PCT

    def test_subtotal_exatamente_300_reais_nao_libera(self) -> None:
        # A regra é "acima de R$ 300", não "a partir de".
        assert max_discount_pct((item(qty=1, price=300_00),)) == 0

    def test_quantidade_soma_entre_itens(self) -> None:
        items = (item("BK001", 2, 1000), item("BK002", 1, 1000))
        assert max_discount_pct(items) == DISCOUNT_TIER_SMALL_PCT


class TestConstrucaoDaCotacao:
    def test_sem_desconto_pedido_total_e_o_subtotal(self) -> None:
        quote = build_quote((item(qty=3, price=1000),))
        assert quote.subtotal_cents == 3000
        assert quote.discount_pct == 0
        assert quote.total_cents == 3000
        assert quote.max_discount_pct == DISCOUNT_TIER_SMALL_PCT

    def test_desconto_dentro_do_teto_e_aplicado(self) -> None:
        quote = build_quote((item(qty=3, price=1000),), requested_discount_pct=5)
        assert quote.discount_pct == 5
        assert quote.discount_cents == 150
        assert quote.total_cents == 2850
        assert quote.discount_was_capped is False

    def test_desconto_acima_do_teto_e_limitado_e_sinalizado(self) -> None:
        quote = build_quote((item(qty=3, price=1000),), requested_discount_pct=80)
        assert quote.discount_pct == DISCOUNT_TIER_SMALL_PCT
        assert quote.total_cents == 2850
        assert quote.discount_was_capped is True

    def test_prompt_injection_pedindo_cem_porcento_nao_zera_o_total(self) -> None:
        """Defesa central: o LLM só pede desconto, nunca define preço."""
        quote = build_quote((item(qty=1, price=5000),), requested_discount_pct=100)
        assert quote.discount_pct == 0
        assert quote.total_cents == 5000

    def test_desconto_negativo_e_tratado_como_zero(self) -> None:
        quote = build_quote((item(qty=5, price=1000),), requested_discount_pct=-30)
        assert quote.discount_pct == 0
        assert quote.total_cents == 5000

    def test_arredondamento_nunca_concede_desconto_a_mais(self) -> None:
        # 10% de 1999 = 199,9 centavos. Deve virar 199, não 200.
        quote = build_quote((item(qty=5, price=1999 // 5 + 1),), 10)
        assert quote.discount_cents == quote.subtotal_cents * 10 // 100

    def test_cotacao_vazia_e_rejeitada(self) -> None:
        with pytest.raises(ValueError):
            build_quote(())

    @pytest.mark.parametrize("quantidade", [0, -1, 11, 99])
    def test_quantidade_fora_da_faixa_e_rejeitada(self, quantidade: int) -> None:
        with pytest.raises(ValueError):
            build_quote((item(qty=quantidade),))
