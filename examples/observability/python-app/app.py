#!/usr/bin/env python3
"""
Exemple d'application Python avec observabilité complète :
- Métriques Prometheus
- Logs structurés JSON
- Traces OpenTelemetry
"""
import json
import logging
import random
import time
from flask import Flask, request
from prometheus_client import Counter, Histogram, generate_latest
from opentelemetry import trace, metrics as otel_metrics
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.instrumentation.flask import FlaskInstrumentor

# ============================================================================
# Configuration de l'observabilité
# ============================================================================

# Logs structurés
logging.basicConfig(
    format='%(message)s',
    level=logging.INFO
)

class JSONFormatter(logging.Formatter):
    def format(self, record):
        # Récupérer le contexte de trace actuel
        span = trace.get_current_span()
        trace_id = format(span.get_span_context().trace_id, '032x') if span.is_recording() else None
        span_id = format(span.get_span_context().span_id, '016x') if span.is_recording() else None
        
        log_data = {
            'timestamp': self.formatTime(record),
            'level': record.levelname.lower(),
            'logger': record.name,
            'message': record.getMessage(),
            'traceid': trace_id,
            'spanid': span_id,
        }
        
        # Ajouter les champs extra
        if hasattr(record, 'user_id'):
            log_data['user_id'] = record.user_id
        if hasattr(record, 'endpoint'):
            log_data['endpoint'] = record.endpoint
            
        return json.dumps(log_data)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger(__name__)
logger.handlers = [handler]
logger.setLevel(logging.INFO)

# OpenTelemetry Traces
resource = Resource.create({
    "service.name": "python-demo-app",
    "service.version": "1.0.0",
    "deployment.environment": "production"
})

trace_provider = TracerProvider(resource=resource)
otlp_trace_exporter = OTLPSpanExporter(
    endpoint="alloy.tenant-root.svc.cluster.local:4317",
    insecure=True
)
trace_provider.add_span_processor(BatchSpanProcessor(otlp_trace_exporter))
trace.set_tracer_provider(trace_provider)
tracer = trace.get_tracer(__name__)

# OpenTelemetry Metrics
otlp_metric_exporter = OTLPMetricExporter(
    endpoint="alloy.tenant-root.svc.cluster.local:4317",
    insecure=True
)
metric_reader = PeriodicExportingMetricReader(otlp_metric_exporter, export_interval_millis=15000)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
otel_metrics.set_meter_provider(meter_provider)
meter = otel_metrics.get_meter(__name__)

# Métriques Prometheus (classiques)
REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)

REQUEST_DURATION = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration in seconds',
    ['method', 'endpoint']
)

# Métriques OpenTelemetry (envoyées via OTLP)
otel_request_counter = meter.create_counter(
    "app.requests.total",
    description="Total number of requests"
)

otel_request_duration = meter.create_histogram(
    "app.request.duration",
    unit="ms",
    description="Request duration in milliseconds"
)

# ============================================================================
# Application Flask
# ============================================================================

app = Flask(__name__)

# Auto-instrumentation Flask (traces automatiques)
FlaskInstrumentor().instrument_app(app)

@app.route('/health')
def health():
    """Health check endpoint"""
    return {'status': 'healthy'}, 200

@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint"""
    return generate_latest(), 200, {'Content-Type': 'text/plain; charset=utf-8'}

@app.route('/')
def index():
    """Root endpoint"""
    with tracer.start_as_current_span("index") as span:
        span.set_attribute("http.route", "/")
        
        logger.info("Accessed root endpoint")
        
        REQUEST_COUNT.labels(method='GET', endpoint='/', status='200').inc()
        otel_request_counter.add(1, {"endpoint": "/", "method": "GET"})
        
        return {
            'message': 'Python Demo App - Observability Example',
            'endpoints': ['/health', '/metrics', '/api/users', '/api/slow', '/api/error']
        }

@app.route('/api/users')
def users():
    """Simule une API avec appel DB"""
    start_time = time.time()
    
    with tracer.start_as_current_span("get_users") as span:
        span.set_attribute("http.route", "/api/users")
        user_id = request.args.get('id', 'all')
        span.set_attribute("user.id", user_id)
        
        logger.info("Fetching users", extra={'endpoint': '/api/users', 'user_id': user_id})
        
        # Simule un appel DB
        with tracer.start_as_current_span("database.query") as db_span:
            db_span.set_attribute("db.system", "postgresql")
            db_span.set_attribute("db.statement", "SELECT * FROM users WHERE id = ?")
            db_span.set_attribute("db.name", "app_db")
            
            time.sleep(random.uniform(0.01, 0.1))  # Simule latence DB
            
            users_data = [
                {'id': 1, 'name': 'Alice'},
                {'id': 2, 'name': 'Bob'},
            ]
        
        duration = time.time() - start_time
        
        REQUEST_COUNT.labels(method='GET', endpoint='/api/users', status='200').inc()
        REQUEST_DURATION.labels(method='GET', endpoint='/api/users').observe(duration)
        otel_request_counter.add(1, {"endpoint": "/api/users", "method": "GET"})
        otel_request_duration.record(duration * 1000, {"endpoint": "/api/users"})
        
        logger.info("Users fetched successfully", extra={
            'endpoint': '/api/users',
            'user_id': user_id,
            'count': len(users_data),
            'duration_ms': duration * 1000
        })
        
        return {'users': users_data, 'count': len(users_data)}

@app.route('/api/slow')
def slow():
    """Endpoint intentionnellement lent"""
    start_time = time.time()
    
    with tracer.start_as_current_span("slow_operation") as span:
        span.set_attribute("http.route", "/api/slow")
        
        logger.warning("Slow endpoint called", extra={'endpoint': '/api/slow'})
        
        # Simule une opération lente
        time.sleep(random.uniform(1.0, 3.0))
        
        duration = time.time() - start_time
        REQUEST_COUNT.labels(method='GET', endpoint='/api/slow', status='200').inc()
        REQUEST_DURATION.labels(method='GET', endpoint='/api/slow').observe(duration)
        
        logger.info("Slow operation completed", extra={
            'endpoint': '/api/slow',
            'duration_ms': duration * 1000
        })
        
        return {'message': 'Completed slow operation', 'duration': duration}

@app.route('/api/error')
def error():
    """Endpoint qui génère des erreurs aléatoires"""
    with tracer.start_as_current_span("error_prone") as span:
        span.set_attribute("http.route", "/api/error")
        
        if random.random() < 0.5:
            # 50% de chance d'erreur
            logger.error("Random error occurred", extra={'endpoint': '/api/error'})
            
            span.set_status(trace.Status(trace.StatusCode.ERROR, "Random error"))
            span.record_exception(Exception("Random error"))
            
            REQUEST_COUNT.labels(method='GET', endpoint='/api/error', status='500').inc()
            return {'error': 'Something went wrong'}, 500
        else:
            logger.info("Error endpoint succeeded", extra={'endpoint': '/api/error'})
            REQUEST_COUNT.labels(method='GET', endpoint='/api/error', status='200').inc()
            return {'message': 'Success'}

@app.route('/api/chain')
def chain():
    """Endpoint qui fait des appels en chaîne (propagation de trace)"""
    with tracer.start_as_current_span("chain_operation") as span:
        span.set_attribute("http.route", "/api/chain")
        
        logger.info("Starting chained operation", extra={'endpoint': '/api/chain'})
        
        # Simule plusieurs sous-opérations
        with tracer.start_as_current_span("step_1"):
            time.sleep(0.1)
            logger.info("Step 1 completed")
        
        with tracer.start_as_current_span("step_2"):
            time.sleep(0.15)
            logger.info("Step 2 completed")
        
        with tracer.start_as_current_span("step_3"):
            time.sleep(0.05)
            logger.info("Step 3 completed")
        
        return {'message': 'Chain completed', 'steps': 3}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
