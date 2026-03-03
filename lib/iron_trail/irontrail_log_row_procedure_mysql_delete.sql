CREATE PROCEDURE IF NOT EXISTS irontrail_log_row_delete(
  IN p_table_name VARCHAR(255),
  IN p_rec_id TEXT,
  IN p_old_data JSON
)
BEGIN
  DECLARE v_actor_type TEXT DEFAULT NULL;
  DECLARE v_actor_id TEXT DEFAULT NULL;
  
  INSERT INTO irontrail_changes 
    (actor_id, actor_type, rec_table, operation, rec_id, rec_old, metadata, created_at)
  VALUES 
    (v_actor_id, v_actor_type, p_table_name, 'd', p_rec_id, p_old_data, NULL, CURRENT_TIMESTAMP);
END;
