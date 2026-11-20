-- SPDX-License-Identifier: MIT
barWidget.setGlyph("sparkles")
barWidget.setText("")
barWidget.setTooltip(noctalia.tr("title"))

function onClick()
  noctalia.togglePanel("barrulus/umbriel-shaders:shaders")
end
