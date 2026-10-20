CLASS zcl_db_log_fail_prep DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_fail_prep IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS c_source_name TYPE zdb_event_count-source_name
      VALUE 'PRODUCT_PRICE_LOG'.

    "------------------------------------------------------------
    " 1. Determine the next event sequence
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_event_count
      FIELDS last_event_seq
      WHERE source_name = @c_source_name
      INTO @DATA(lv_last_event_seq).

    IF sy-subrc <> 0.
      out->write( 'Event counter not found.' ).
      RETURN.
    ENDIF.

    DATA(lv_conflict_seq) = lv_last_event_seq + 1.
    DATA(lv_event_at)     = utclong_current( ).

    "------------------------------------------------------------
    " 2. Remove a leftover test conflict, if any
    "------------------------------------------------------------
    DELETE FROM zdb_change_log
      WHERE source_name = @c_source_name
        AND event_seq   = @lv_conflict_seq
        AND product_id  = 'PFAIL'
        AND store_group = 'TEST'.

    " No error if nothing had to be deleted.


    "------------------------------------------------------------
    " 3. Create a deliberate duplicate-key conflict
    "------------------------------------------------------------
    DATA(ls_event) = VALUE zdb_change_log(
      client      = sy-mandt
      source_name = c_source_name
      event_seq   = lv_conflict_seq
      product_id  = 'PFAIL'
      store_group = 'TEST'
      operation   = 'I'
      price       = '999.00'
      currency    = 'EUR'
      event_at    = lv_event_at
    ).

    INSERT zdb_change_log FROM @ls_event.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |Failure preparation failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Conflict event created: EVENT_SEQ = { lv_conflict_seq }|
    ).

  ENDMETHOD.

ENDCLASS.
