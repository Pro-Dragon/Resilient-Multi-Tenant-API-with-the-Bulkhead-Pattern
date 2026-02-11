CREATE TABLE tenant_data (
    id SERIAL PRIMARY KEY,
    tier VARCHAR(20) NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO tenant_data (tier, payload) VALUES
('free', '{"message": "Free tier data point 1"}'),
('pro', '{"message": "Pro tier data point 1"}'),
('enterprise', '{"message": "Enterprise tier data point 1"}');
