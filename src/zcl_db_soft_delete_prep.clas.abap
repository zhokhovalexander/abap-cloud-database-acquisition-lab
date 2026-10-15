CLASS zcl_db_soft_delete_prep DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_soft_delete_prep IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA(lv_change_at) = utclong_current( ).

    DATA(ls_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = 'P1003'
      store_group = 'SOUTH'
      price       = '30.00'
      currency    = 'EUR'
      created_seq = 1010
      changed_at  = lv_change_at
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_price.

    IF sy-subrc <> 0.
      out->write(
        |Restore failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |P1003/SOUTH restored. CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
