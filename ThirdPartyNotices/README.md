<!-- Created by Василий Маслов on 04.10.2026. -->
# Third-party notices

Original license text is retained without adding an authorship header. These libraries support the Swift application and its bundled MCP panel. Versions/revisions are pinned by Package.resolved and Web/pnpm-lock.yaml. The TypeScript panel embeds legal comments emitted by its bundler. Development tools and their transitive packages are not needed on the user's machine.

Mimic's own license is [MIT](../LICENSE). Dependency licenses apply to their respective components; the root license does not replace them. App packaging includes this directory and Mimic's LICENSE, and the setup ZIP includes a separate copy of LICENSE.

## Swift package inventory

The pinned source licenses were compared with the local dependency checkouts during preparation.

| Package | Version | License text |
| --- | --- | --- |
| Sparkle | 2.10.0 | [Original MIT and bundled component notices](Sparkle-LICENSE.txt) |
| SwiftTerm | 1.20.0 | [MIT](SwiftTerm-LICENSE.txt) |
| ZIPFoundation | 0.9.20 | [MIT](ZIPFoundation.md) |
| MCP Swift SDK | 0.12.1 | [Original transition notices: Apache 2.0/MIT](mcp-swift-sdk-LICENSE.txt) |
| eventsource (Swift) | 1.5.1 | [MIT](eventsource-LICENSE.txt) |
| swift-argument-parser | 1.8.2 | [Apache 2.0](swift-argument-parser-LICENSE.txt) |
| swift-atomics | 1.3.1 | [Apache 2.0](swift-atomics-LICENSE.txt) |
| swift-collections | 1.7.1 | [Apache 2.0](swift-collections-LICENSE.txt) |
| swift-log | 1.15.1 | [Apache 2.0](swift-log-LICENSE.txt) |
| swift-nio | 2.103.0 | [Apache 2.0](swift-nio-LICENSE.txt), bundled [llhttp MIT](llhttp-LICENSE.txt) |
| swift-system | 1.8.1 | [Apache 2.0](swift-system-LICENSE.txt) |

## Bundled panel inventory

The following packages are present in esbuild's input graph for the current panel. This is a bundle inventory, not the entire SDK/server dependency graph.

| Package | Version | License text |
| --- | --- | --- |
| @modelcontextprotocol/ext-apps | 1.7.5 | [Original notices](mcp-ext-apps-LICENSE.txt) |
| @modelcontextprotocol/sdk | 1.29.0 | [MIT](mcp-typescript-sdk-LICENSE.txt) |
| @openai/mcp-extensions | 0.1.0 | [Apache 2.0](openai-mcp-extensions-LICENSE.txt) |
| @xterm/xterm | 6.0.0 | [MIT](xterm-LICENSE.txt) |
| @xterm/addon-fit | 0.11.0 | [MIT](xterm-addon-fit-LICENSE.txt) |
| zod | 4.4.3 | [MIT](zod-LICENSE.txt) |
| zod-to-json-schema | 3.25.2 | [ISC](zod-to-json-schema-LICENSE.txt) |

The previously retained [cfworker notice](cfworker-LICENSE.txt) remains available for SDK dependencies. Adapted usage algorithms/catalogs are attributed separately in [OpenUsage](OpenUsage/README.md). Their public catalogs retain their original schemas.

When changing dependencies, compare the new source licenses, check the actual bundle inputs, update this inventory and regenerate the panel. Standard third-party license texts retain upstream authorship and do not receive Mimic creation comments.
