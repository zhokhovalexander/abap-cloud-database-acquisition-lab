CLASS zcl_db_ts_delayed_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_delayed_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA(lv_change_at) = utclong_current( ).

    UPDATE zdb_src_price
      SET price      = '22.00',
          changed_at = @lv_change_at
      WHERE product_id  = 'P1002'
        AND store_group = 'SOUTH'.

    IF sy-subrc <> 0.
      out->write(
        |UPDATE failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    out->write(
      |Pending UPDATE: P1002/SOUTH -> 22.00, CHANGED_AT = { lv_change_at }|
    ).

    " Manual debugging anchor:
    " pause here BEFORE COMMIT WORK.
    DATA(lv_debug_anchor) = abap_true.

    COMMIT WORK.

    out->write( 'Delayed UPDATE committed.' ).

  ENDMETHOD.

ENDCLASS.
