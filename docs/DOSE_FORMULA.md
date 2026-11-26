# Dose formula (toy model two)

Reference for the formula edited in **Manage > menu > Dose formulas**. The same text is available in the app from the **Help** link at the top of that screen. Code: `Sources/DoseFormula.swift`.

## What it computes

`B(t)` is the modelled impact on blood glucose `t` minutes after eating, on a one-minute grid from 0 to 720 minutes. It is a toy model: its shape is chosen by hand, not fitted to data, and it is not yet used for the forecast or the bolus values.

## Inputs

| Input | Source | Role |
|---|---|---|
| carbs | accepted food's carbohydrate grams, adjusted by the fiber setting | drives the **fast** component |
| protein | accepted food's protein grams | drives the **slow** component |
| fat | accepted food's fat grams | sets only the **smear time**; adds no glucose |

Missing amounts count as 0.

Fiber setting (carbohydrate section): *Total carbs* uses carbs as entered; *Net (fiber ÷ 2)* uses `max(carbs − fiber/2, 0)`; *Net (all fiber)* uses `max(carbs − fiber, 0)`. Missing fiber counts as 0.

## The seven factors

| Group | Name | Symbol | Default | Unit | Meaning |
|---|---|---|---|---|---|
| Time | fast peak | `t1` | 20 | min | time of the fast component's peak |
| Time | slow hold center | `t2` | 240 | min | middle of the slow component's flat top |
| Time | smear per gram of fat | `σ` | 26.3 | min per g fat | smear width added by each gram of fat |
| Amplitude | carbs (fast) | `A1` | 1.0 | per g carbs | weight of the fast component |
| Amplitude | protein (slow) | `A2` | 1.5 | per g protein | weight of the slow component |
| Amplitude | overall scale | `C` | 0.5 | – | scales the whole curve |
| Offset | baseline | `b` | 0 | – | added to every minute |

Fixed (not editable): hold length `H = 120` min, edge width `w = 60` min.

## Formulas

Total curve:

```
B(t) = b + C · ( s * [ A1·carbs·g_fast + A2·protein·g_hold ] )(t)
```

`*` is convolution over minutes.

**Fast component** — gamma with shape 2 and mode `t1`, unit area:

```
g_fast(t) = (t / t1²) · e^(−t / t1)        for t ≥ 0, else 0
```

It is two equal exponential steps in series, each `t1` minutes long, so it peaks at `t1`.

**Slow component** — flat top built from two logistic edges, centered at `t2`, hold `H`, edge width `w`:

```
L(x)      = 1 / (1 + e^(−x))
raw(t)    = L((t − t2 + H/2) / w) − L((t − t2 − H/2) / w)
g_hold(t) = raw(t) / Σ raw(t')          (normalized to unit area on the grid 0…720)
```

**Smear** — Gaussian kernel whose mean delay equals its standard deviation `σ_eff`, for `τ ≥ 0`:

```
σ_eff = σ × fat grams
s(τ)  ∝ exp[ −½ ((τ − σ_eff) / σ_eff)² ]      (normalized to sum 1)
```

The kernel is truncated at `6·σ_eff` minutes. With no fat (`σ_eff < 0.01`) the kernel is a single 1, so there is no smear.

Because `g_fast`, `g_hold` and `s` each have unit area, the curve's total area is `C·(A1·carbs + A2·protein)` before `b`. Fat therefore moves and flattens the curve but does not change its total.

## Landmark conversions

The model parameters can be described by features read off a plot. These conversions are exact for the logistic and Gaussian shapes:

| Landmark | Symbol | Model parameter | Conversion | Value with defaults |
|---|---|---|---|---|
| time to peak | `T_peak` | `t1` | `t1 = T_peak` | 20 min |
| hold start / end | `T_on`, `T_off` | `t2`, `H` | `t2 = (T_on + T_off)/2`, `H = T_off − T_on` | 180 / 300 → 240, 120 |
| 10%–90% rise time | `R` | `w` | `w = R / (2 ln 9)` | 263.6 → 60 |
| time for 90% of blur | `B90` | `σ_eff` | `σ_eff = B90 / (1 + 1.2816)` | 60 → 26.3 |

`2 ln 9 ≈ 4.394` is the 10%–90% span of a logistic curve in units of its width. `1.2816` is the normal z-score for 90%. Because `σ_eff = σ × fat grams`, the app's `σ` equals `B90 / 2.2816` for 1 g of fat. `H` and `w` are fixed in the app, so only `T_peak`, the center of the hold, and `B90` are adjustable there.

## Default curve check

With 1 g each of carbs, protein and fat and the defaults, the curve peaks at 0.0065 at minute 62, dips to about 0.0020 at minute 166, has a second hump of about 0.0029 near minute 276, and is effectively 0 by minute 600. `Tests/MFSTests/DoseFormulaTests.swift` asserts these values.

## Numerics

- One-minute grid, minutes 0…720; later minutes return 0.
- `impact(...)` linearly interpolates between grid minutes.
- Values are per the units of the inputs (grams); there is no unit conversion to mg/dL yet. Treat results as relative until the factors are fitted to data.

## Known limits

- Hand-chosen shapes; the factors are expected to be fitted to data later.
- Fat only affects timing. Any person-specific effect of fat on insulin action is not modelled.
- Glucose level does not enter the formula.
