"""Palavras-chave de uma busca que vem da conversa.

"quero um livro sobre ciúme, por favor" vira ["ciume"]. Palavras de ligação e
de pedido não dizem nada sobre o livro e, se entrassem na busca, puxariam títulos
que só por acaso as contêm, como "Ensaio sobre a Cegueira".
"""

from __future__ import annotations

import re
import unicodedata

MAX_KEYWORDS = 12

STOPWORDS = frozenset("""
    a ao aos aquela aquele as ate com como da das de dela dele do dos e ela ele em entre era
    essa esse esta este eu foi favor gostaria ha isso me mais mas meu minha na nas nao no nos
    o obrigado obrigada os ou para pela pelo per por porque pra pro qual quais quando que
    quem se sem ser seu sobre sua tem tenho tipo um uma umas uns vai voce voces
    algo alguem algum alguma alguns algumas ajuda busca buscar comprar compro encontrar
    gosto indica indicacao indique levar livro livros leitura ler mostra mostrar obra obras
    oi ola pode poderia preciso procuro procurando quero queria recomenda recomendacao
    recomende sugere sugestao tens titulo titulos ver
""".split())


def _fold(text: str) -> str:
    decomposed = unicodedata.normalize("NFD", text.lower())
    return "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")


def extract_keywords(query: str) -> list[str]:
    """Termos em minúsculas, sem acento e só com letras e números.

    Se a busca só tiver palavras de ligação, elas mesmas viram os termos: o cliente
    pode estar procurando exatamente isso. O alfabeto restrito também deixa os termos
    seguros para entrar em expressões regulares no SQL.
    """
    tokens = list(dict.fromkeys(re.findall(r"[a-z0-9]+", _fold(query))))
    keywords = [t for t in tokens if t not in STOPWORDS and len(t) >= 2]
    return (keywords or tokens)[:MAX_KEYWORDS]
