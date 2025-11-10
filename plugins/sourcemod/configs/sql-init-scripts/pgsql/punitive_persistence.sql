-- =====================================================
-- Persistent Punishments - PostgreSQL Database Schema
-- =====================================================

-- Main punishments table
CREATE TABLE IF NOT EXISTS punishments (
    punishment_id SERIAL PRIMARY KEY,
    punishment_type VARCHAR(32) NOT NULL,
    target_steamid VARCHAR(32),
    target_ip VARCHAR(64),
    target_name VARCHAR(64),
    admin_steamid VARCHAR(32),
    admin_name VARCHAR(64),
    reason VARCHAR(255),
    issued_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP,
    is_active BOOLEAN DEFAULT TRUE
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Index for checking active punishments by SteamID
CREATE INDEX IF NOT EXISTS idx_punishments_steamid 
ON punishments(target_steamid, is_active);

-- Index for checking active punishments by IP
CREATE INDEX IF NOT EXISTS idx_punishments_ip 
ON punishments(target_ip, is_active);

-- Index for expiration cleanup queries
CREATE INDEX IF NOT EXISTS idx_punishments_expires 
ON punishments(expires_at);

-- Compound index for active punishment lookups
CREATE INDEX IF NOT EXISTS idx_punishments_active_expires 
ON punishments(is_active, expires_at);

-- =====================================================
-- Constraints
-- =====================================================

-- Ensure at least one target identifier exists
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'chk_target_identifier'
    ) THEN
        ALTER TABLE punishments 
        ADD CONSTRAINT chk_target_identifier 
        CHECK (target_steamid IS NOT NULL OR target_ip IS NOT NULL);
    END IF;
END $$;

-- Ensure punishment type is valid
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'chk_punishment_type'
    ) THEN
        ALTER TABLE punishments 
        ADD CONSTRAINT chk_punishment_type 
        CHECK (punishment_type IN ('ban_steamid', 'ban_ip', 'gag', 'mute', 'silence'));
    END IF;
END $$;

-- =====================================================
-- Example Data
-- =====================================================

-- Example permanent ban by SteamID:
-- INSERT INTO punishments (punishment_type, target_steamid, target_name, admin_steamid, admin_name, reason, expires_at) 
-- VALUES ('ban_steamid', 'STEAM_0:1:12345678', 'BadPlayer', 'STEAM_0:1:87654321', 'AdminName', 'Cheating', NULL);

-- Example timed IP ban (expires in 24 hours):
-- INSERT INTO punishments (punishment_type, target_ip, admin_steamid, admin_name, reason, expires_at) 
-- VALUES ('ban_ip', '192.168.1.100', 'STEAM_0:1:87654321', 'AdminName', 'Griefing', CURRENT_TIMESTAMP + INTERVAL '24 hours');

-- Example permanent gag:
-- INSERT INTO punishments (punishment_type, target_steamid, target_name, admin_steamid, admin_name, expires_at) 
-- VALUES ('gag', 'STEAM_0:1:12345678', 'SpammyPlayer', 'STEAM_0:1:87654321', 'AdminName', NULL);

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all active punishments
-- SELECT * FROM punishments WHERE is_active = TRUE;

-- View all active bans
-- SELECT * FROM punishments 
-- WHERE is_active = TRUE 
-- AND punishment_type IN ('ban_steamid', 'ban_ip')
-- AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP);

-- Deactivate expired punishments (run periodically)
-- UPDATE punishments 
-- SET is_active = FALSE 
-- WHERE is_active = TRUE 
-- AND expires_at IS NOT NULL 
-- AND expires_at < CURRENT_TIMESTAMP;

-- Find all punishments by a specific admin
-- SELECT * FROM punishments WHERE admin_steamid = 'STEAM_0:1:87654321';

-- Find all punishments for a specific player
-- SELECT * FROM punishments WHERE target_steamid = 'STEAM_0:1:12345678';

-- Count punishments by type
-- SELECT punishment_type, COUNT(*) as count 
-- FROM punishments 
-- WHERE is_active = TRUE 
-- GROUP BY punishment_type;

-- Find players with multiple active punishments
-- SELECT target_steamid, target_name, COUNT(*) as punishment_count 
-- FROM punishments 
-- WHERE is_active = TRUE 
-- GROUP BY target_steamid, target_name 
-- HAVING COUNT(*) > 1
-- ORDER BY punishment_count DESC;

-- Delete old inactive punishments (older than 90 days)
-- DELETE FROM punishments 
-- WHERE is_active = FALSE 
-- AND issued_at < CURRENT_TIMESTAMP - INTERVAL '90 days';

-- =====================================================
-- Optional: Automatic Cleanup Function
-- =====================================================

-- Function to automatically deactivate expired punishments
CREATE OR REPLACE FUNCTION deactivate_expired_punishments()
RETURNS INTEGER AS $$
DECLARE
    affected_rows INTEGER;
BEGIN
    UPDATE punishments 
    SET is_active = FALSE 
    WHERE is_active = TRUE 
    AND expires_at IS NOT NULL 
    AND expires_at < CURRENT_TIMESTAMP;
    
    GET DIAGNOSTICS affected_rows = ROW_COUNT;
    RETURN affected_rows;
END;
$$ LANGUAGE plpgsql;

-- You can call this function periodically via a cron job or manually:
-- SELECT deactivate_expired_punishments();

-- =====================================================
-- Optional: Audit Log Table
-- =====================================================

-- Uncomment if you want to track all changes to punishments
-- CREATE TABLE IF NOT EXISTS punishments_audit (
--     audit_id SERIAL PRIMARY KEY,
--     punishment_id INTEGER,
--     action VARCHAR(32),
--     changed_by VARCHAR(32),
--     changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
--     old_values JSONB,
--     new_values JSONB
-- );
-- 
-- CREATE INDEX IF NOT EXISTS idx_audit_punishment 
-- ON punishments_audit(punishment_id);
-- 
-- CREATE INDEX IF NOT EXISTS idx_audit_time 
-- ON punishments_audit(changed_at);
