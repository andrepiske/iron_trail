CREATE PROCEDURE IF NOT EXISTS irontrail_log_row_update(
  IN p_table_name VARCHAR(255),
  IN p_rec_id TEXT,
  IN p_old_data JSON,
  IN p_new_data JSON
)
BEGIN
  DECLARE v_actor_type TEXT DEFAULT NULL;
  DECLARE v_actor_id TEXT DEFAULT NULL;
  DECLARE v_created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
  DECLARE v_metadata JSON DEFAULT NULL;
  DECLARE v_delta JSON DEFAULT JSON_OBJECT();
  DECLARE v_updated_at_old TEXT DEFAULT NULL;
  DECLARE v_updated_at_new TEXT DEFAULT NULL;
  
  -- For MySQL, we'll store the full old and new data without computing delta
  -- The delta can be computed in Ruby if needed
  
  -- Extract updated_at if present and changed
  SET v_updated_at_old = JSON_UNQUOTE(JSON_EXTRACT(p_old_data, '$.updated_at'));
  SET v_updated_at_new = JSON_UNQUOTE(JSON_EXTRACT(p_new_data, '$.updated_at'));
  IF v_updated_at_new IS NOT NULL AND v_updated_at_new != 'null' AND v_updated_at_new != v_updated_at_old THEN
    SET v_created_at = v_updated_at_new;
    SET v_metadata = JSON_OBJECT('_db_created_at', CURRENT_TIMESTAMP);
  END IF;
  
  INSERT INTO irontrail_changes 
    (actor_id, actor_type, rec_table, operation, rec_id, rec_old, rec_new, rec_delta, metadata, created_at)
  VALUES 
    (v_actor_id, v_actor_type, p_table_name, 'u', p_rec_id, p_old_data, p_new_data, v_delta, v_metadata, v_created_at);
END;
