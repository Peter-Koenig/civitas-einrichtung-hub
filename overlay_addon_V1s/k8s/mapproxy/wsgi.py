"""MapProxy-WSGI-Einstieg (analog p2d2-Standalone wsgi:application)."""
import os

from mapproxy.wsgiapp import make_wsgi_app

application = make_wsgi_app(
    os.environ.get("MAPROXY_CONFIG", "/mapproxy/mapproxy.yaml")
)
