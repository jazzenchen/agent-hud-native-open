"""Windows entry point; the views port the original SwiftUI view tree."""
import json
import sys
import os


def prepare_desktop_environment(environment,arguments,platform=None):
    """Test rendering may be headless; an ordinary desktop launch must be visible."""
    if (os.name if platform is None else platform)=='nt' and '--preview-dir' not in arguments and '--probe' not in arguments:
        environment['QT_QPA_PLATFORM']='windows'

if __name__ == '__main__':
    if '--probe' in sys.argv:
        from runtime import running_clients
        print(json.dumps({'running': sorted(running_clients())}))
    else:
        prepare_desktop_environment(os.environ,sys.argv[1:])
        from application import main
        main()
