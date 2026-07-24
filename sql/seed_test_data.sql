INSERT INTO audit_logs (event_type, payload, created_at)
VALUES
  (
    'old-login',
    '{"source": "integration-test"}',
    CURRENT_TIMESTAMP - INTERVAL '120 days'
  ),
  (
    'old-export',
    '{"source": "integration-test"}',
    CURRENT_TIMESTAMP - INTERVAL '100 days'
  ),
  (
    'old-update',
    '{"source": "integration-test"}',
    CURRENT_TIMESTAMP - INTERVAL '91 days'
  ),
  (
    'recent-login',
    '{"source": "integration-test"}',
    CURRENT_TIMESTAMP - INTERVAL '30 days'
  ),
  (
    'recent-update',
    '{"source": "integration-test"}',
    CURRENT_TIMESTAMP - INTERVAL '1 day'
  );

