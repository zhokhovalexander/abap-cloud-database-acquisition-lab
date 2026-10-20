CLASS zcl_db_full_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_full_reader IMPLEMENTATION.



  METHOD if_oo_adt_classrun~main.

  "------------------------------------------------------------
  " 1. Create extraction run ID
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
  " 2. FULL read from source
  "------------------------------------------------------------
  SELECT FROM zdb_src_price
    FIELDS product_id,
           store_group,
           price,
           currency,
           created_seq,
           changed_at,
           is_deleted
    ORDER BY product_id, store_group
    INTO TABLE @DATA(lt_source).

  out->write(
    |FULL extraction: { lines( lt_source ) } rows.|
  ).

  "------------------------------------------------------------
  " 3. Prepare acquisition persistence
  "------------------------------------------------------------
  DATA lt_acq TYPE TABLE OF zdb_acq_price.

  LOOP AT lt_source ASSIGNING FIELD-SYMBOL(<ls_source>).

    APPEND VALUE #(
      client      = sy-mandt
      run_id      = lv_run_id
      product_id  = <ls_source>-product_id
      store_group = <ls_source>-store_group
      load_type   = 'FULL'
      price       = <ls_source>-price
      currency    = <ls_source>-currency
      created_seq = <ls_source>-created_seq
      changed_at  = <ls_source>-changed_at
      is_deleted  = <ls_source>-is_deleted
      acquired_at = lv_acquired_at
    ) TO lt_acq.

  ENDLOOP.

  "------------------------------------------------------------
  " 4. Persist extracted rows
  "------------------------------------------------------------
  INSERT zdb_acq_price FROM TABLE @lt_acq.

    IF sy-subrc <> 0.
        ROLLBACK WORK.

        out->write(
            |FULL acquisition persistence failed. SY-SUBRC = { sy-subrc }|
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

 ENDMETHOD.

ENDCLASS.
