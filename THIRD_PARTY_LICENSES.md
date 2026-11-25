# Third-Party Dependencies

This repository uses third-party dependencies. This document lists direct dependencies; their licenses are governed by their respective projects.

## Node.js (`packages/bridge`)
- `ws` (`^8.18.0`, https://github.com/websockets/ws)
  - Used by: `nonlocal-bridge` WebSocket server
  - License: MIT License
- `commander` (`^12.1.0`, https://github.com/tj/commander.js)
  - Used by: `nonlocal-bridge` CLI
  - License: MIT License

## Swift Package Manager (`ios`)
- `acp-swift-sdk` (https://github.com/rebornix/acp-swift-sdk)
  - Used by: `ACPClient`
  - License: see the `acp-swift-sdk` repository
- `ListViewKit` (https://github.com/Lakr233/ListViewKit)
  - Used by: `Agmente`
  - License: see the `ListViewKit` repository
- `MarkdownView` (https://github.com/Lakr233/MarkdownView)
  - Used by: `Agmente`
  - License: see the `MarkdownView` repository

## Bundled JavaScript Assets
- `mermaid` v11.12.0 (`ios/Agmente/Resources/mermaid.min.js`, https://github.com/mermaid-js/mermaid)
  - Used by: `Agmente` offline Mermaid diagram rendering (`MermaidRenderer`)
  - License: MIT License (Copyright (c) 2014 - 2024 Knut Sveidqvist)

If you add new dependencies, update this file accordingly.
