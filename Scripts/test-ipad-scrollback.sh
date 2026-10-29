#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: test-ipad-scrollback.sh <device-udid> <development-team>" >&2
    exit 2
fi
for tool in python3 xcodegen xcodebuild; do
    command -v "$tool" >/dev/null || { echo "required tool: $tool" >&2; exit 1; }
done

repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
review_workspace=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-ipad-scrollback.XXXXXX")
echo "Benchmark workspace (including results): $review_workspace"

# Scrollback compression gates (spec.scrollback.md §13) on a physical device.
# SwiftPM's tool-hosted tests cannot run there, so an application host is
# generated outside the repository.
python3 - "$review_workspace" "$repository_root" "$2" <<'PY'
from pathlib import Path
import json
import sys

workspace, repository, team = sys.argv[1:]
root = Path(workspace)
(root / 'App.swift').write_text('''import SwiftUI
@main struct ScrollbackReviewApp: App {
    var body: some Scene {
        WindowGroup { Text("Swiftty scrollback benchmark") }
    }
}
''')
project = {
    'name': 'SwifttyScrollbackReview',
    'options': {'deploymentTarget': {'iOS': '27.0'}},
    'settings': {'base': {
        'DEVELOPMENT_TEAM': team, 'CODE_SIGN_STYLE': 'Automatic',
        'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES',
    }},
    'packages': {'Swiftty': {'path': repository}},
    'targets': {
        'SwifttyScrollbackReview': {
            'type': 'application', 'platform': 'iOS', 'sources': ['App.swift'],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.chr33s.swiftty.review.scrollback',
                'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
            }},
        },
        'ScrollbackTests': {
            'type': 'bundle.unit-test', 'platform': 'iOS',
            'sources': [str(Path(repository) / 'Tests/SwifttyMobileTests/ScrollbackDeviceTests.swift')],
            'dependencies': [
                {'target': 'SwifttyScrollbackReview'},
                {'package': 'Swiftty', 'product': 'SwifttyCore'},
            ],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'dev.chr33s.swiftty.review.scrollback.tests',
                'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/SwifttyScrollbackReview.app/SwifttyScrollbackReview',
                'BUNDLE_LOADER': '$(TEST_HOST)',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS':
                    '$(inherited) SWIFTTY_REQUIRE_SCROLLBACK_BENCHMARK',
            }},
        },
    },
    'schemes': {'SwifttyScrollbackReview': {
        'build': {'targets': {'SwifttyScrollbackReview': 'all', 'ScrollbackTests': ['test']}},
        'test': {'targets': ['ScrollbackTests']},
    }},
}
(root / 'project.json').write_text(json.dumps(project, indent=2) + '\n')
PY

cd "$review_workspace"
xcodegen generate --spec project.json
xcodebuild -scheme SwifttyScrollbackReview -configuration Release \
    -destination "platform=iOS,id=$1" -derivedDataPath "$review_workspace/build" \
    -resultBundlePath "$review_workspace/Scrollback.xcresult" \
    -collect-test-diagnostics never test
