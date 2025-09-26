# Copilot Instructions for ZMK Sofle Keyboard

## Project Overview
This is a ZMK-based firmware project for the Eyelash Sofle keyboard - a split ergonomic keyboard with rotary encoders, RGB underglow, nice!view displays, and mouse/pointing device support.

## Architecture & Key Components

### Core Structure
- **`config/`** - Main keyboard configuration (keymap, features, west manifest)
- **`boards/arm/eyelash_sofle/`** - Board definition files for Zephyr/ZMK
- **`build.yaml`** - Defines build artifacts for left/right halves with nice_view shield
- **`keymap-drawer/`** - Auto-generated SVG keymap visualizations

### Build System
- Uses ZMK's standard build system with GitHub Actions
- Builds triggered on config changes via `.github/workflows/build.yml`
- Keymap visualizations auto-generated via `.github/workflows/draw.yml` using keymap-drawer

## Development Patterns

### Keymap Configuration (`config/eyelash_sofle.keymap`)
- 3-layer layout: base (layer0), function (layer_1), system (layer_2)
- Combos defined for soft-off (`Q+S+Z` held 2s) and studio unlock (`ESC+BACKSPACE`)
- Mouse movement via `&mmv` behaviors with custom acceleration settings
- Rotary encoder contexts: volume control (base), scrolling (layer_1)

### Feature Configuration (`config/eyelash_sofle.conf`)
- **Power Management**: 1-hour sleep timeout, auto RGB shutoff
- **ZMK Studio**: Enabled for visual keymap editing (unlocking disabled)
- **RGB**: Max brightness 90%, auto-off on idle/USB, starts with hue 160
- **Connectivity**: BT with +8dBm TX power for better range

### Board Definition Patterns
- Split into `eyelash_sofle_left.dts` and `eyelash_sofle_right.dts`
- Common definitions in `eyelash_sofle.dtsi`
- Layout definitions in `eyelash_sofle-layouts.dtsi`

## Key Development Workflows

### Testing Changes
1. Modify configs in `config/` directory
2. Push to trigger automatic build in GitHub Actions
3. Download artifacts from Actions tab (`.uf2` files)
4. Flash via bootloader mode (double-tap reset button)

### Keymap Visualization
- Keymap changes automatically generate new SVG files in `keymap-drawer/`
- Configuration in `keymap_drawer.config.yaml` controls visual styling
- Uses Ubuntu Mono font with custom color schemes for different key states

### Power Optimization
- RGB underglow configured to auto-disable (saves significant power on right half)
- 1-hour sleep timeout with wake-on-keypress
- Soft-off feature for travel (wake via reset button only)

## Project-Specific Conventions

### Layer Naming
- `layer0`: Base typing layer with arrow keys on thumb cluster
- `layer_1`: Function keys, mouse controls, RGB controls
- `layer_2`: System controls (Bluetooth, reset, bootloader)

### Mouse Integration
- Custom pointing device settings with scaled movement and scrolling
- Encoder context-switching (volume vs scroll based on active layer)
- Click behaviors integrated into keymap (`&mkp LCLK`, etc.)

### Bluetooth Management
- Multi-device support with BT_SEL 0-4 on layer_2
- Clear all profiles via `BT_CLR_ALL`
- Output switching between USB/BLE via `OUT_USB`/`OUT_BLE`

## Critical Files for Changes
- **`config/eyelash_sofle.keymap`** - All key assignments and behaviors
- **`config/eyelash_sofle.conf`** - Feature flags and hardware settings
- **`build.yaml`** - Build target configuration
- **`boards/arm/eyelash_sofle/*.dts`** - Hardware pin definitions and device tree

When making changes, always test both halves and all layers, as this is a complex split keyboard with multiple input methods (keys, encoder, mouse).