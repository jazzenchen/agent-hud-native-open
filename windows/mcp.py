"""The stdio process does not create a window or start the resident app."""
import sys
from mcp_protocol import Server,serve


def main():
    from mcp_channel import call
    from source_design import DESIGN
    serve(sys.stdin.buffer,sys.stdout.buffer,Server(DESIGN['app_version'],call))


if __name__=='__main__':main()
