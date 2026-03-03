DROP PROCEDURE IF EXISTS irontrail_log_row;

CREATE PROCEDURE irontrail_log_row(
  IN p_operation CHAR(1),
  IN p_table_name VARCHAR(255),
  IN p_rec_id TEXT,
  IN p_old_obj JSON,
  IN p_new_obj JSON,
  IN p_created_at_val DATETIME(6),
  IN p_updated_at_old DATETIME(6),
  IN p_updated_at_new DATETIME(6)
)
BEGIN
  DECLARE v_it_meta TEXT;
  DECLARE v_it_meta_obj JSON;
  DECLARE v_actor_type TEXT;
  DECLARE v_actor_id TEXT;
  DECLARE v_created_at DATETIME(6);
  DECLARE v_u_changes JSON;
  DECLARE v_key_name VARCHAR(255);
  DECLARE v_value_a JSON;
  DECLARE v_value_b JSON;
  DECLARE v_keys_done INT DEFAULT 0;
  DECLARE v_all_keys JSON;
  DECLARE v_i INT;
  DECLARE v_num_keys INT;
  DECLARE v_has_created_at INT DEFAULT 0;
  DECLARE v_has_updated_at INT DEFAULT 0;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1
      @p_sqlstate = RETURNED_SQLSTATE,
      @p_message = MESSAGE_TEXT;

    INSERT INTO `irontrail_trigger_errors` (`mysql_errcode`, `mysql_message`,
        `err_text`, `op`, `table_name`,
        `old_data`, `new_data`, `query`, `created_at`)
      VALUES (@p_sqlstate, @p_message, @p_message, p_operation, p_table_name,
        p_old_obj, p_new_obj, 'N/A', NOW(6));
  END;

  SET v_it_meta = @irontrail_metadata;

  SET v_actor_type = NULL;
  SET v_actor_id = NULL;
  SET v_it_meta_obj = NULL;

  IF v_it_meta IS NOT NULL AND v_it_meta != '' THEN
    SET v_it_meta_obj = CAST(v_it_meta AS JSON);

    IF JSON_CONTAINS_PATH(v_it_meta_obj, 'one', '$._actor_type') THEN
      SET v_actor_type = JSON_UNQUOTE(JSON_EXTRACT(v_it_meta_obj, '$._actor_type'));
      SET v_it_meta_obj = JSON_REMOVE(v_it_meta_obj, '$._actor_type');
    END IF;
    IF JSON_CONTAINS_PATH(v_it_meta_obj, 'one', '$._actor_id') THEN
      SET v_actor_id = JSON_UNQUOTE(JSON_EXTRACT(v_it_meta_obj, '$._actor_id'));
      SET v_it_meta_obj = JSON_REMOVE(v_it_meta_obj, '$._actor_id');
    END IF;
  END IF;

  -- Determine created_at for the change record
  SET v_created_at = NULL;

  IF p_operation = 'i' AND p_created_at_val IS NOT NULL THEN
    SET v_created_at = p_created_at_val;
  ELSEIF p_operation = 'u' AND p_updated_at_new IS NOT NULL THEN
    IF p_updated_at_old IS NULL OR p_updated_at_new != p_updated_at_old THEN
      SET v_created_at = p_updated_at_new;
    END IF;
  END IF;

  IF v_created_at IS NULL THEN
    SET v_created_at = NOW(6);
  ELSE
    IF v_it_meta_obj IS NULL OR JSON_TYPE(v_it_meta_obj) = 'NULL' THEN
      SET v_it_meta_obj = JSON_OBJECT('_db_created_at', DATE_FORMAT(NOW(6), '%Y-%m-%d %H:%i:%s.%f'));
    ELSE
      SET v_it_meta_obj = JSON_SET(v_it_meta_obj, '$._db_created_at', DATE_FORMAT(NOW(6), '%Y-%m-%d %H:%i:%s.%f'));
    END IF;
  END IF;

  -- Normalize empty meta object
  IF v_it_meta_obj IS NOT NULL AND JSON_TYPE(v_it_meta_obj) = 'OBJECT' AND JSON_LENGTH(v_it_meta_obj) = 0 THEN
    SET v_it_meta_obj = NULL;
  END IF;

  IF p_operation = 'i' THEN
    INSERT INTO `irontrail_changes` (`actor_id`, `actor_type`,
      `rec_table`, `operation`, `rec_id`, `rec_new`, `metadata`, `created_at`)
    VALUES (v_actor_id, v_actor_type,
      p_table_name, 'i', p_rec_id, p_new_obj, v_it_meta_obj, v_created_at);

  ELSEIF p_operation = 'u' THEN
    -- Only log if there's an actual change
    IF NOT (CAST(p_old_obj AS CHAR) = CAST(p_new_obj AS CHAR)) THEN
      -- Compute delta
      SET v_u_changes = JSON_OBJECT();

      -- Get all keys from both objects
      SET v_all_keys = irontrail_merged_keys(p_old_obj, p_new_obj);
      SET v_num_keys = JSON_LENGTH(v_all_keys);
      SET v_i = 0;

      WHILE v_i < v_num_keys DO
        SET v_key_name = JSON_UNQUOTE(JSON_EXTRACT(v_all_keys, CONCAT('$[', v_i, ']')));
        SET v_value_a = JSON_EXTRACT(p_old_obj, CONCAT('$.', v_key_name));
        SET v_value_b = JSON_EXTRACT(p_new_obj, CONCAT('$.', v_key_name));

        IF NOT (v_value_a <=> v_value_b) OR
           (v_value_a IS NULL AND v_value_b IS NOT NULL) OR
           (v_value_a IS NOT NULL AND v_value_b IS NULL) THEN
          SET v_u_changes = JSON_SET(v_u_changes, CONCAT('$.', v_key_name), JSON_ARRAY(v_value_a, v_value_b));
        END IF;

        SET v_i = v_i + 1;
      END WHILE;

      INSERT INTO `irontrail_changes` (`actor_id`, `actor_type`, `rec_table`, `operation`,
        `rec_id`, `rec_old`, `rec_new`, `rec_delta`, `metadata`, `created_at`)
      VALUES (v_actor_id, v_actor_type, p_table_name, 'u', p_rec_id, p_old_obj, p_new_obj, v_u_changes, v_it_meta_obj, v_created_at);

    END IF;
  ELSEIF p_operation = 'd' THEN
    INSERT INTO `irontrail_changes` (`actor_id`, `actor_type`, `rec_table`, `operation`,
      `rec_id`, `rec_old`, `metadata`, `created_at`)
    VALUES (v_actor_id, v_actor_type, p_table_name, 'd', p_rec_id, p_old_obj, v_it_meta_obj, v_created_at);

  END IF;
END;
