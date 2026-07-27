INSERT INTO audit_logs_test (log_message, created_at)
VALUES
  (
    'old-login',
    LOCALTIMESTAMP - INTERVAL '120 days'
  ),
  (
    'old-export',
    LOCALTIMESTAMP - INTERVAL '100 days'
  ),
  (
    'old-update',
    LOCALTIMESTAMP - INTERVAL '91 days'
  ),
  (
    'recent-login',
    LOCALTIMESTAMP - INTERVAL '30 days'
  ),
  (
    'recent-update',
    LOCALTIMESTAMP - INTERVAL '1 day'
  );
