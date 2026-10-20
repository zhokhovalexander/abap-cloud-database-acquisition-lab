CLASS zcl_db_soft_delete DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_soft_delete IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_product_id  TYPE zdb_src_price-product_id
        VALUE 'P1003',
      c_store_group TYPE zdb_src_price-store_group
        VALUE 'SOUTH'.

    DATA(lv_change_at) = utclong_current( ).

    "------------------------------------------------------------
    " Soft DELETE experiment.
    "
    " The source row remains physically present.
    " IS_DELETED marks the logical deletion and CHANGED_AT
    " makes the change visible to timestamp-based delta.
    "------------------------------------------------------------

     UPDATE zdb_src_price
      SET is_deleted = 'X',
          changed_at = @lv_change_at
      WHERE product_id  = @c_product_id
        AND store_group = @c_store_group.

    IF sy-subrc <> 0.
      out->write(
        |Soft delete failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |{ c_product_id }/{ c_store_group } marked as deleted. |
      && |CHANGED_AT = { lv_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
