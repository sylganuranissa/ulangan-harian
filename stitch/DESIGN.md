---
name: Paymi Design System
colors:
  surface: '#faf8ff'
  surface-dim: '#d2d9f4'
  surface-bright: '#faf8ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f2f3ff'
  surface-container: '#eaedff'
  surface-container-high: '#e2e7ff'
  surface-container-highest: '#dae2fd'
  on-surface: '#131b2e'
  on-surface-variant: '#484554'
  inverse-surface: '#283044'
  inverse-on-surface: '#eef0ff'
  outline: '#797585'
  outline-variant: '#cac4d6'
  surface-tint: '#6345cc'
  primary: '#431cac'
  on-primary: '#ffffff'
  primary-container: '#5b3cc4'
  on-primary-container: '#d1c5ff'
  inverse-primary: '#cbbeff'
  secondary: '#615a78'
  on-secondary: '#ffffff'
  secondary-container: '#e4dbfe'
  on-secondary-container: '#655f7c'
  tertiary: '#3e25a4'
  on-tertiary: '#ffffff'
  tertiary-container: '#5641bc'
  on-tertiary-container: '#cec5ff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#e7deff'
  primary-fixed-dim: '#cbbeff'
  on-primary-fixed: '#1e0061'
  on-primary-fixed-variant: '#4b28b3'
  secondary-fixed: '#e7deff'
  secondary-fixed-dim: '#cac2e4'
  on-secondary-fixed: '#1d1831'
  on-secondary-fixed-variant: '#49435f'
  tertiary-fixed: '#e5deff'
  tertiary-fixed-dim: '#c8bfff'
  on-tertiary-fixed: '#1a0063'
  on-tertiary-fixed-variant: '#452fab'
  background: '#faf8ff'
  on-background: '#131b2e'
  surface-variant: '#dae2fd'
  background-alt: '#F9FAFB'
  text-muted: '#64748B'
  border-subtle: '#E2E8F0'
  glass-fill: rgba(255, 255, 255, 0.8)
typography:
  headline-xl:
    fontFamily: Plus Jakarta Sans
    fontSize: 64px
    fontWeight: '700'
    lineHeight: 72px
    letterSpacing: -0.04em
  headline-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  headline-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.01em
  label-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.02em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  container-max: 1200px
  gutter: 24px
  margin-mobile: 16px
  margin-desktop: 32px
  section-padding: 96px
  stack-xs: 4px
  stack-sm: 8px
  stack-md: 16px
  stack-lg: 24px
  stack-xl: 48px
---

## Brand & Style

The design system is built for a high-performance Fintech environment, blending the stability of traditional finance with the agility of modern SaaS. The brand personality is professional, sleek, and high-tech, aiming to evoke a sense of security and effortless movement of capital.

The visual style is **Corporate Modern with Glassmorphism**. It utilizes a clean, expansive white canvas to provide clarity, punctuated by Deep Royal Purple to establish authority. Sophisticated depth is achieved through translucent, frosted-glass layers and soft, multi-layered shadows that make UI components feel physical yet digital. The interface prioritizes high-quality geometric typography and a "Bento-style" grid for data-heavy sections, ensuring complex financial information remains accessible and visually engaging.

## Colors

The palette is anchored by **Deep Royal Purple**, used strategically for primary actions and brand presence. **Soft Lavender** serves as a sophisticated secondary fill, providing a softer landing for grouped content and card backgrounds without the starkness of pure white.

- **Primary:** High-contrast purple for CTA buttons, active navigation, and critical brand touchpoints.
- **Secondary:** Lavender used exclusively for card fills, badges, and background highlights to create a multi-layered surface hierarchy.
- **Neutral:** A deep navy-black for text ensuring maximum legibility (WCAG AAA) and a cool-gray scale for borders and secondary text to maintain a professional, tech-focused atmosphere.

## Typography

This design system uses a dual-font approach. **Plus Jakarta Sans** is the display face, providing a modern, friendly, yet geometric precision for all headlines. **Inter** handles all body copy and functional labels, chosen for its exceptional readability and neutral, professional tone.

For financial data, statistics, and transaction lists, always enable **tabular figures** (monospaced numbers) to ensure columns of currency align perfectly. Maintain tight letter-spacing on large headlines to emphasize the "sleek" brand personality.

## Layout & Spacing

The system follows a strict **12-column fluid grid** for desktop, reflowing to a single column on mobile devices. 

- **Grid:** On desktop (1200px+), use a 24px gutter. On mobile, use a 16px gutter with 16px side margins.
- **Bento Grid:** For dashboard and statistics sections, utilize a "Bento" layout model where cards of varying sizes (spanning 3, 6, or 9 columns) are grouped with consistent 24px gaps to visualize diverse data streams.
- **Rhythm:** Spacing follows an 8px base unit. Section vertical padding should be generous (80px–120px) to maintain the "clean white canvas" aesthetic and permit the floating UI elements room to breathe.

## Elevation & Depth

Hierarchy is established through a combination of **Tonal Layering** and **Glassmorphism**.

1.  **Base Surface:** Pure white (`#FFFFFF`) for the primary canvas.
2.  **Injected Layers:** Soft Lavender (`#E2D9FC`) used for secondary cards to create immediate visual grouping without the need for heavy borders.
3.  **Floating Glass:** Floating widgets (like transaction previews or conversion calculators) must use a 12px–20px backdrop blur with a 80% white opacity fill. 
4.  **Shadows:** Shadows should be multi-layered and tinted with the primary color at very low opacity (`rgba(91, 60, 196, 0.08)`). Avoid generic black shadows. This creates a "glow" effect that feels high-tech and premium.

## Shapes

The shape language is defined by large, friendly radii that convey safety and modern software sensibilities. 

- **Standard Cards:** Use 16px (`rounded-lg`) for most containers.
- **Large Sections/Feature Cards:** Use 24px (`rounded-xl`) to create a distinct, bold visual boundary.
- **Interactive Elements:** Buttons and tags must always be **Pill-shaped** (`rounded-full`) to differentiate them from static containers and maintain the "Stripe/Revolut" inspired aesthetic.

## Components

### Buttons
Primary buttons use the Deep Royal Purple with white text and a `rounded-full` shape. Secondary buttons use the Soft Lavender fill with Deep Royal Purple text. All buttons include a subtle lift on hover via the tinted shadow.

### Cards
- **Feature Cards:** White background, 1px border (`#E2E8F0`), and 16px corner radius.
- **Glass Widgets:** Use the backdrop-blur style for elements that "float" over the main content (e.g., hero section graphics).

### Input Fields
Inputs should have a clean, white background with a 1px border. On focus, the border transitions to Primary Purple with a 4px soft outer glow (the same primary color at 10% opacity).

### Chips & Badges
Always `rounded-full`. Use Soft Lavender as the background for informational badges and a 10% opacity version of the primary purple for interactive chips.

### Lists & Transactions
Use horizontal dividers only when necessary; otherwise, rely on white space and `body-sm` text in `text-muted` for metadata. Numbers should always be tabular to ensure currency alignment.