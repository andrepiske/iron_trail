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
  DECLARE v_delta JSON;
  DECLARE v_updated_at_old TEXT DEFAULT NULL;
  DECLARE v_updated_at_new TEXT DEFAULT NULL;
  DECLARE v_old_keys JSON;
  DECLARE v_new_keys JSON;
  DECLARE v_all_keys TEXT;
  DECLARE v_key TEXT;
  DECLARE v_old_val JSON;
  DECLARE v_new_val JSON;
  DECLARE i INT DEFAULT 0;
  DECLARE j INT DEFAULT 0;
  DECLARE v_old_keys_count INT;
  DECLARE v_new_keys_count INT;
  
  -- Initialize delta as empty object
  SET v_delta = JSON_OBJECT();
  
  -- Get keys from old and new data
  SET v_old_keys = JSON_KEYS(p_old_data);
  SET v_new_keys = JSON_KEYS(p_new_data);
  SET v_old_keys_count = JSON_LENGTH(v_old_keys);
  SET v_new_keys_count = JSON_LENGTH(v_new_keys);
  
  -- Process keys from old data
  SET i = 0;
  WHILE i < v_old_keys_count DO
    SET v_key = JSON_UNQUOTE(JSON_EXTRACT(v_old_keys, CONCAT('$[', i, ']')));
    SET v_old_val = JSON_EXTRACT(p_old_data, CONCAT('$.', v_key));
    SET v_new_val = JSON_EXTRACT(p_new_data, CONCAT('$.', v_key));
    
    -- Check if values are different (using JSON comparison)
    IF NOT (v_old_val <=> v_new_val) THEN
      SET v_delta = JSON_MERGE_PATCH(v_delta, JSON_OBJECT(v_key, JSON_ARRAY(v_old_val, v_new_val)));
    END IF;
    
    SET i = i + 1;
  END WHILE;
  
  -- Process keys that exist only in new data
  SET j = 0;
  WHILE j < v_new_keys_count DO
    SET v_key = JSON_UNQUOTE(JSON_EXTRACT(v_new_keys, CONCAT('$[', j, ']')));
    SET v_old_val = JSON_EXTRACT(p_old_data, CONCAT('$.', v_key));
    
    -- If key doesn't exist in old data (IS NULL), add it to delta
    IF v_old_val IS NULL THEN
      SET v_new_val = JSON_EXTRACT(p_new_data, CONCAT('$.', v_key));
      SET v_delta = JSON_MERGE_PATCH(v_delta, JSON_OBJECT(v_key, JSON_ARRAY(CAST('null' AS JSON), v_new_val)));
    END IF;
    
    SET j = j + 1;
  END WHILE;
  
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
