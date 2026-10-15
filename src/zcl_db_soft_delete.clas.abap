CLASS zcl_db_soft_delete DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_soft_delete IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA(lv_change_at) = utclong_current( ).

    UPDATE zdb_src_price
      SET is_deleted = 'X',
          changed_at = @lv_change_at
      WHERE product_id  = 'P1003'
        AND store_group = 'SOUTH'.

    IF sy-subrc <> 0.
      out->write(
        |Soft delete failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |P1003/SOUTH marked as deleted. CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
