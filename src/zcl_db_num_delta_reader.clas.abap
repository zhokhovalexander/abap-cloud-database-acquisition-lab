CLASS zcl_db_num_delta_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_num_delta_reader IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS c_source_name TYPE zdb_delta_state-source_name
      VALUE 'PRODUCT_PRICE'.

    "------------------------------------------------------------
    " 1. Read current delta pointer
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_delta_state
      FIELDS last_seq
      WHERE source_name = @c_source_name
      INTO @DATA(lv_last_seq).

    IF sy-subrc <> 0.
      out->write(
        |Delta state not found for source { c_source_name }.|
      ).
      RETURN.
    ENDIF.

    out->write(
      |Current LAST_SEQ = { lv_last_seq }|
    ).

    "------------------------------------------------------------
    " 2. Read numeric delta
    "------------------------------------------------------------
    SELECT FROM zdb_src_price
      FIELDS product_id,
             store_group,
             price,
             currency,
             created_seq,
             changed_at,
             is_deleted
      WHERE created_seq > @lv_last_seq
      ORDER BY created_seq
      INTO TABLE @DATA(lt_source).

    out->write(
      |Numeric delta: { lines( lt_source ) } rows selected.|
    ).

    IF lt_source IS INITIAL.
      out->write( 'No new numeric delta records.' ).
      RETURN.
    ENDIF.

    "------------------------------------------------------------
    " 3. Create extraction run
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

    "------------------------------------------------------------
    " 4. Prepare acquisition persistence
    "------------------------------------------------------------
    DATA lt_acq TYPE TABLE OF zdb_acq_price.
    DATA lv_new_last_seq TYPE zdb_delta_state-last_seq.

    LOOP AT lt_source ASSIGNING FIELD-SYMBOL(<ls_source>).

      APPEND VALUE #(
        client      = sy-mandt
        run_id      = lv_run_id
        product_id  = <ls_source>-product_id
        store_group = <ls_source>-store_group
        load_type   = 'NUMERIC'
        price       = <ls_source>-price
        currency    = <ls_source>-currency
        created_seq = <ls_source>-created_seq
        changed_at  = <ls_source>-changed_at
        is_deleted  = <ls_source>-is_deleted
        acquired_at = lv_acquired_at
      ) TO lt_acq.

      lv_new_last_seq = <ls_source>-created_seq.

    ENDLOOP.

    "------------------------------------------------------------
    " 5. Persist delta and advance pointer
    "    in the same logical transaction
    "------------------------------------------------------------
    INSERT zdb_acq_price FROM TABLE @lt_acq.

    IF sy-subrc <> 0.
      ROLLBACK WORK.
      out->write(
        |Acquisition persistence failed. SY-SUBRC = { sy-subrc }|
      ).
      RETURN.
    ENDIF.

    UPDATE zdb_delta_state
      SET last_seq = @lv_new_last_seq
      WHERE source_name = @c_source_name.

    IF sy-subrc <> 0.
      ROLLBACK WORK.
      out->write(
        |Delta pointer update failed. SY-SUBRC = { sy-subrc }|
      ).
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Run ID: { lv_run_id }|
    ).

    out->write(
      |Persisted: { lines( lt_acq ) } rows.|
    ).

    out->write(
      |New LAST_SEQ = { lv_new_last_seq }|
    ).

  ENDMETHOD.

ENDCLASS.


