#!/usr/bin/env python3
"""COMPLETE collision audit for the short-word (2-letter) frequency signal.

Unlike a top-N corpus check, this enumerates the FULL preimage set: every
2-letter input whose layout image is a listed word in the OTHER language. The
app converts such an input unless the input itself is in its OWN list, so the
only false-convert risk is a REAL word/abbreviation whose image is a listed word
but which is missing from its own list. We check the curated lists against a
reference of real 2-letter tokens and assert closure (exit 1 on any risk).

Keep SHORT_RU / SHORT_EN below in sync with
macos/Sources/TypeFlow/ShortWords.swift.
"""
import sys

EN2RU = dict(zip("qwertyuiopasdfghjklzxcvbnm",
                 "йцукенгшщзфывапролдячсмить"))
RU2EN = {v: k for k, v in EN2RU.items()}

def img_en_to_ru(w): return "".join(EN2RU.get(c, "?") for c in w)
def img_ru_to_en(w): return "".join(RU2EN.get(c, "?") for c in w)

# ---- lists under test (must match ShortWords.swift) ----
SHORT_RU = set("не ты на он мы вы да но за бы же из ну по то от их ее её со ли ни об ей во им ко те та уж ок эй го".split())
SHORT_EN = set("to it of is in we me he my on do no be so go if up at as an us or by am ok hi oh ah um mr ya vs dj kb bp ds".split())

# Product preference: lowercase `ye` and `jr` are deliberately treated as the
# mistyped Russian words «ну» and «ок». Keep the exceptions explicit so the
# audit still catches every other accidental collision.
FORCED_EN_TO_RU = {"ye", "jr"}

# ---- reference of REAL 2-letter tokens (words + common abbreviations) ----
# English: Scrabble TWL two-letter words + abbreviations common in prose.
REF_EN = set(("aa ab ad ae ag ah ai al am an ar as at aw ax ay ba be bi bo by da de do "
              "ed ef eh el em en er es et ex fa fe gi go ha he hi hm ho id if in is it jo "
              "ka ki la li lo ma me mi mm mo mu my na ne no nu od oe of oh oi om on op or "
              "os ow ox oy pa pe pi po qi re sh si so ta te ti to uh um un up ur us ut we "
              "wo xi xu ya ye yo za "
              "vs dj tv kb mb gb jr sr mr ms dr st pm ds").split())
# Russian: common real 2-letter words.
REF_RU = set(("не ни но на ну ты вы мы он да за до по из от об во со то та ту те их им ей ею её ее го "
              "же ли бы ко уж ок ад ас ум ус юг юр эх ах ох ой эй яд як ял ил ел ем еж").split())

def check(name, ref, own, other_list, img):
    risks = []
    for t in sorted(ref):
        if name.startswith("EN->RU") and t in FORCED_EN_TO_RU:
            continue
        c = img(t)
        if "?" in c:
            continue
        if c in other_list and t not in own:
            risks.append((t, c))
    print(f"=== {name}: real tokens that would wrongly convert ===")
    for t, c in risks:
        print(f"  RISK: «{t}» -> «{c}» (image listed, «{t}» not in own list)")
    print(f"  risks: {len(risks)}")
    return len(risks)

r1 = check("EN->RU (typing real English)", REF_EN, SHORT_EN, SHORT_RU, img_en_to_ru)
r2 = check("RU->EN (typing real Russian)", REF_RU, SHORT_RU, SHORT_EN, img_ru_to_en)

print("\n=== ambiguous pairs (both listed -> declined, safe) ===")
for w in sorted(SHORT_EN):
    c = img_en_to_ru(w)
    if c in SHORT_RU:
        print(f"  en «{w}» <-> ru «{c}»")

print("\n=== sanity: key conversions still fire ===")
for t, expect in [("yt", "не"), ("ns", "ты"), ("yf", "на"), ("lf", "да"),
                  ("ye", "ну"), ("jr", "ок"), ("uj", "го")]:
    c = img_en_to_ru(t)
    fires = c in SHORT_RU and t not in SHORT_EN
    print(f"  type en '{t}' -> ru «{c}» converts? {fires} (want True; image==expect: {c==expect})")

sys.exit(1 if (r1 + r2) else 0)
