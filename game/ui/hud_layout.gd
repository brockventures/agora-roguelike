class_name HudLayout
extends RefCounted
## HUD v3 "command deck" screen geometry (design system, HUD v2.dc.html frame 3a), in
## 1280x800 screen px. The map is the root on top; below it a three-column deck holds
## the order ladder, the order ticket and the crisis card. These rects are the screen
## layout. OrbitalHUD.TACTICAL_MAP_RECT and SolTacticalMap.MAP_CENTER stay the tactical
## map's model space (the sim-facing projection that tests pin); Main maps that space
## onto MAP_RECT at draw time (see MainScene._map_point).
## Presentation only: nothing here reaches sim state, saves or hashes.

const VIEWPORT: Vector2 = Vector2(1280.0, 800.0)
const HEADER_RECT: Rect2 = Rect2(0.0, 0.0, 1280.0, 64.0)
const MAP_RECT: Rect2 = Rect2(0.0, 64.0, 1280.0, 456.0)
const DECK_RECT: Rect2 = Rect2(0.0, 520.0, 1280.0, 280.0)
## Deck columns 440 / 400 / 1fr with an 8 px gutter and 8 px padding (grid-template-columns in 3a).
const LADDER_RECT: Rect2 = Rect2(8.0, 528.0, 440.0, 264.0)
const TICKET_RECT: Rect2 = Rect2(456.0, 528.0, 400.0, 264.0)
const CARD_RECT: Rect2 = Rect2(864.0, 528.0, 408.0, 264.0)
## The Market tab's quote board and the Fleet tab's panel float over the map.
const BOARD_RECT: Rect2 = Rect2(24.0, 112.0, 560.0, 340.0)
const FLEET_RECT: Rect2 = Rect2(24.0, 112.0, 860.0, 340.0)
## Modals centre on the map region; the small ones (Chapter 11, perks banner) use MODAL_RECT.
const MODAL_RECT: Rect2 = Rect2(340.0, 96.0, 600.0, 360.0)
const MODAL_WIDE_RECT: Rect2 = Rect2(220.0, 76.0, 840.0, 400.0)
const BANNER_RECT: Rect2 = Rect2(300.0, 236.0, 680.0, 160.0)
## Ink contour inside every plate (hud_theme.tres) and the content padding.
const BORDER: float = 4.0
const PAD: float = 12.0
## The map's two-line GalNet strip along the bottom of the map region (4 px inside the
## map's ink contour, 56 px tall at 100%; Main grows it with the text scale).
const TICKER_RECT: Rect2 = Rect2(4.0, 460.0, 1272.0, 56.0)
## Where the map's orbit system sits inside MAP_RECT (above the ticker strip) and the
## ellipse foreshortening of the model's circular orbits: the 3a frame draws Ceres' orbit
## as rx 420 / ry 196.
const MAP_ORIGIN: Vector2 = Vector2(640.0, 252.0)
const MAP_STRETCH: Vector2 = Vector2(1.34, 0.56)
