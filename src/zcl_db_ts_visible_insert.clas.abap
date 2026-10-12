CLASS zcl_db_ts_visible_insert DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_visible_insert IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA(lv_change_at) = utclong_current( ).

    DATA(ls_new_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = 'P1007'
      store_group = 'SOUTH'
      price       = '70.00'
      currency    = 'EUR'
      created_seq = 1008
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
      |Visible INSERT committed: P1007/SOUTH, CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
