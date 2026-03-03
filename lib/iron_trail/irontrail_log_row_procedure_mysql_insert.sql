CREATE PROCEDURE IF NOT EXISTS irontrail_log_row_insert(
  IN p_table_name VARCHAR(255),
  IN p_rec_id TEXT,
  IN p_new_data JSON
)
BEGIN
  DECLARE v_actor_type TEXT DEFAULT NULL;
  DECLARE v_actor_id TEXT DEFAULT NULL;
  DECLARE v_created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
  DECLARE v_metadata JSON DEFAULT NULL;
  DECLARE v_created_at_val TEXT DEFAULT NULL;
  
  -- Extract created_at if present
  SET v_created_at_val = JSON_UNQUOTE(JSON_EXTRACT(p_new_data, '$.created_at'));
  IF v_created_at_val IS NOT NULL AND v_created_at_val != 'null' THEN
    SET v_created_at = v_created_at_val;
    SET v_metadata = JSON_OBJECT('_db_created_at', CURRENT_TIMESTAMP);
  END IF;
  
  INSERT INTO irontrail_changes 
    (actor_id, actor_type, rec_table, operation, rec_id, rec_new, metadata, created_at)
  VALUES 
    (v_actor_id, v_actor_type, p_table_name, 'i', p_rec_id, p_new_data, v_metadata, v_created_at);
END;
