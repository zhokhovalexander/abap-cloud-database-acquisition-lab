CLASS zcl_db_ts_source_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_source_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA(lv_change_at) = utclong_current( ).

    "------------------------------------------------------------
    " 1. Update an existing old record
    "    CREATED_SEQ intentionally remains unchanged
    "------------------------------------------------------------
    UPDATE zdb_src_price
      SET price      = '13.00',
          changed_at = @lv_change_at
      WHERE product_id  = 'P1001'
        AND store_group = 'SOUTH'.

    IF sy-subrc <> 0.
      out->write(
        |UPDATE failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    "------------------------------------------------------------
    " 2. Insert a new source record
    "------------------------------------------------------------
    DATA(ls_new_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = 'P1005'
      store_group = 'SOUTH'
      price       = '50.00'
      currency    = 'EUR'
      created_seq = 1006
      changed_at  = lv_change_at
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_new_price.

    IF sy-subrc <> 0.
      out->write(
        |INSERT failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |UPDATE: P1001/SOUTH -> 13.00, CHANGED_AT = { lv_change_at }|
    ).

    out->write(
      |INSERT: P1005/SOUTH, CREATED_SEQ = 1006, CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
