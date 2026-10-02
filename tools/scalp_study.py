#!/usr/bin/env python3
"""scalp_study.py : разбор журналов скальпера (только стандартная библиотека Python).

    python tools/scalp_study.py [папка_с_журналами] [--days N]

Читает scalp_gaps_*.csv, scalp_cycles_*.csv, scalp_fills_*.csv и отвечает на вопросы калибровки:
  1. ДЫРКИ: дырка у рынка - временная пустота или новая цена? По причине (снятие / вынос) и ширине спреда:
     сколько живёт, куда уходит середина через 1/5/30 с ("продолжение" - в сторону отступившей стороны).
     Если после "тихих" (cancel) дырок середина в среднем уходит больше чем на ~0.5 тика - пара будет
     исполняться не той ногой: PAIR_MIN_SPREAD поднять или PAIR выключить.
  2. ЦИКЛЫ: по сетапам (реальные и виртуальные): доля прибыльных, тиков на лот, рубли, фазы выхода.
  3. МАРКАУТЫ входов (+ хорошо для нас) по сетапу и ширине спреда: где исполнение "отравлено".
"""
import csv
import glob
import os
import statistics as st
import sys
from collections import defaultdict


def rows(folder, prefix, days):
    files = sorted(glob.glob(os.path.join(folder, prefix + "_*.csv")))
    if days:
        files = files[-days:]
    out = []
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            out.extend(csv.DictReader(fh))
    return out, files


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def mean(xs):
    xs = [x for x in xs if x is not None]
    return st.mean(xs) if xs else None


def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None


def f(x, d=2):
    return "-" if x is None else f"{x:+.{d}f}"


def bucket_spread(s):
    s = num(s) or 0
    return "3" if s <= 3 else ("4" if s <= 4 else "5+")


def gaps(folder, days):
    data, files = rows(folder, "scalp_gaps", days)
    print(f"\n=== 1. ДЫРКИ (эпизоды спреда >= GAP_MIN_SPREAD): {len(data)} из {len(files)} файлов ===")
    if not data:
        return
    g = defaultdict(list)
    for r in data:
        g[(r["cause"], bucket_spread(r["spread0"]))].append(r)
    print(f"{'причина':8} {'спред':5} {'N':>5} {'жизнь,с':>8} {'mid=':>6} {'прод.1с':>8} {'прод.5с':>8} {'прод.30с':>9}")
    for (cause, sb), rs in sorted(g.items()):
        dur = med([num(r["dur"]) for r in rs])
        same = sum(1 for r in rs if abs(num(r["dmid_end"]) or 0) < 0.5) / len(rs)

        def cont(col):
            vals = []
            for r in rs:
                d = num(r[col])
                side = r["side"]
                if d is None or side not in ("B", "S"):
                    continue
                direction = -1 if side == "B" else 1     # отступили биды -> давление вниз
                vals.append(direction * d)
            return mean(vals)
        print(f"{cause:8} {sb:5} {len(rs):5d} {('-' if dur is None else f'{dur:.2f}'):>8} {same:6.0%} {f(cont('dmid_1')):>8} "
              f"{f(cont('dmid_5')):>8} {f(cont('dmid_30')):>9}")
    print("  mid= - доля дырок, закрывшихся без сдвига середины (хорошо для пары);")
    print("  прод. - сдвиг середины в сторону отступившей стороны, тики (> 0 - дырка = новая цена).")


def cycles(folder, days):
    data, _ = rows(folder, "scalp_cycles", days)
    print(f"\n=== 2. ЦИКЛЫ: {len(data)} ===")
    if not data:
        return
    g = defaultdict(list)
    for r in data:
        g[(r["setup"], r["backend"])].append(r)
    for (setup, be), rs in sorted(g.items()):
        pnl = [num(r["pnl_ticks_per_lot"]) for r in rs]
        wins = sum(1 for p in pnl if p and p > 0)
        rub = sum(num(r["pnl_rub"]) or 0 for r in rs)
        ph = defaultdict(int)
        for r in rs:
            ph[r["exit_phase"]] += 1
        phs = " ".join(f"{k}:{v}" for k, v in sorted(ph.items(), key=lambda x: -x[1]))
        print(f"{setup:5} {be:8} N {len(rs):4d}  win {wins / len(rs):4.0%}  тиков/лот {f(mean(pnl))}  "
              f"руб {rub:+.0f}  удержание {med([num(r['hold_sec']) for r in rs]) or 0:.1f} с  фазы [{phs}]")


def fills(folder, days):
    data, _ = rows(folder, "scalp_fills", days)
    print(f"\n=== 3. МАРКАУТЫ ВХОДОВ (тики, + в нашу сторону): {len(data)} ===")
    if not data:
        return
    g = defaultdict(list)
    for r in data:
        g[(r["setup"], r["backend"], bucket_spread(r["spread"]))].append(r)
    print(f"{'сетап':5} {'режим':8} {'спред':5} {'N':>5} {'1с':>7} {'5с':>7} {'30с':>7}")
    for (setup, be, sb), rs in sorted(g.items()):
        print(f"{setup:5} {be:8} {sb:5} {len(rs):5d} {f(mean([num(r['mk1']) for r in rs])):>7} "
              f"{f(mean([num(r['mk5']) for r in rs])):>7} {f(mean([num(r['mk30']) for r in rs])):>7}")
    print("  Маркаут входа при паре должен быть > -(захват спреда): иначе вторая нога не окупает первую.")


def main():
    import argparse
    ap = argparse.ArgumentParser(description="разбор журналов скальпера")
    ap.add_argument("folder", nargs="?", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--days", type=int, default=None, help="только последние N дней")
    a = ap.parse_args()
    gaps(a.folder, a.days)
    cycles(a.folder, a.days)
    fills(a.folder, a.days)


if __name__ == "__main__":
    main()
