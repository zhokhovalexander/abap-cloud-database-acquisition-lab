CLASS zcl_db_log_delta_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_delta_reader IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS c_source_name TYPE zdb_delta_state-source_name
      VALUE 'PRODUCT_PRICE_LOG'.


    "------------------------------------------------------------
    " 1. Read consumer pointer
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_delta_state
      FIELDS last_seq
      WHERE source_name = @c_source_name
      INTO @DATA(lv_last_seq).

    IF sy-subrc <> 0.
      out->write(
        |Consumer state not found for source { c_source_name }.|
      ).
      RETURN.
    ENDIF.

    out->write(
      |Current consumer LAST_SEQ = { lv_last_seq }|
    ).


    "------------------------------------------------------------
    " 2. Read committed change-log events
    "------------------------------------------------------------
    SELECT FROM zdb_change_log
      FIELDS event_seq,
             product_id,
             store_group,
             operation,
             price,
             currency,
             event_at
      WHERE source_name = @c_source_name
        AND event_seq   > @lv_last_seq
      ORDER BY event_seq
      INTO TABLE @DATA(lt_events).

    out->write(
      |Change-log delta: { lines( lt_events ) } events selected.|
    ).

    IF lt_events IS INITIAL.
      out->write( 'No new change-log events.' ).
      RETURN.
    ENDIF.


    "------------------------------------------------------------
    " 3. Create acquisition run
    "------------------------------------------------------------
    TRY.
        DATA(lv_run_id) =
          cl_system_uuid=>create_uuid_c32_static( ).

      CATCH cx_uuid_error INTO DATA(lx_uuid).
        out->write(
          |UUID creation failed: { lx_uuid->get_text( ) }|
        ).
        RETURN.
    ENDTRY.

    DATA(lv_acquired_at) = utclong_current( ).

    DATA lt_acq TYPE TABLE OF zdb_acq_price.
    DATA lv_new_last_seq TYPE zdb_delta_state-last_seq.


    "------------------------------------------------------------
    " 4. Prepare acquisition persistence
    "
    " Events are ordered by EVENT_SEQ ascending,
    " therefore the last processed EVENT_SEQ is the new pointer.
    "------------------------------------------------------------
    LOOP AT lt_events ASSIGNING FIELD-SYMBOL(<ls_event>).

      APPEND VALUE #(
        client      = sy-mandt
        run_id      = lv_run_id
        event_seq   = <ls_event>-event_seq
        product_id  = <ls_event>-product_id
        store_group = <ls_event>-store_group
        load_type   = 'LOG_DELTA'
        operation   = <ls_event>-operation
        price       = <ls_event>-price
        currency    = <ls_event>-currency
  " EVENT_AT is stored in the generic acquisition timestamp field for information ONLY.
        changed_at  = <ls_event>-event_at
        acquired_at = lv_acquired_at
      ) TO lt_acq.

      lv_new_last_seq = <ls_event>-event_seq.

    ENDLOOP.


    "------------------------------------------------------------
    " 5. Persist acquired events
    "------------------------------------------------------------
    INSERT zdb_acq_price FROM TABLE @lt_acq.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |Acquisition persistence failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.


    "------------------------------------------------------------
    " 6. Advance CONSUMER pointer
    "
    " This is not the producer counter.
    " It records only successfully acquired events.
    "------------------------------------------------------------
    UPDATE zdb_delta_state
      SET last_seq = @lv_new_last_seq
      WHERE source_name = @c_source_name.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |Consumer pointer update failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.


    "------------------------------------------------------------
    " 7. Commit acquisition and pointer atomically
    "------------------------------------------------------------
    COMMIT WORK.

    out->write(
      |Run ID: { lv_run_id }|
    ).

    out->write(
      |Persisted: { lines( lt_acq ) } events.|
    ).

    out->write(
      |New consumer LAST_SEQ = { lv_new_last_seq }|
    ).

  ENDMETHOD.

ENDCLASS.
