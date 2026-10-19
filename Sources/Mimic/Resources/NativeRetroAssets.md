<!-- Created by Василий Маслов on 13.10.2026. -->
# Native R1 artwork

`native-r1-*.png` and `native-r1-*@2x.png` are 1×/2× raster exports of the repository's original `Web/assets/retro/*.svg`, accepted in Mimic R1. SwiftUI/AppKit draws bevels, borders and gradients directly; bitmap icons use nearest-neighbour sampling and retain both scale representations.

The editable SVG files remain the source. Caption geometry is covered by the existing XP.css MIT notice in `ThirdPartyNotices/XP-css-LICENSE.txt`. No font files are bundled: MS Sans Serif 95 Regular/Bold, Tahoma Regular/Bold and Trebuchet MS Bold must be installed locally.

Binary PNG exports keep their original pixels; authorship and provenance are recorded here rather than inserted into their binary payloads.
