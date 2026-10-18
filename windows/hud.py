"""Windows entry point; the views port the original SwiftUI view tree."""
import json
import sys

if __name__ == '__main__':
    if '--probe' in sys.argv:
        from runtime import running_clients
        print(json.dumps({'running': sorted(running_clients())}))
    else:
        from application import main
        main()
