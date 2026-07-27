CREATE TABLE audit_logs_test (
  uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  log_message text NOT NULL,
  created_at timestamp without time zone NOT NULL
);
