CLASS zcl_db_ts_delayed_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_delayed_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

     CONSTANTS:
      c_product_id  TYPE zdb_src_price-product_id
        VALUE 'P1002',
      c_store_group TYPE zdb_src_price-store_group
        VALUE 'SOUTH',
      c_price       TYPE zdb_src_price-price
        VALUE '23.00'.

    DATA(lv_change_at) = utclong_current( ).

    "------------------------------------------------------------
    " Delayed-COMMIT experiment.
    "
    " CHANGED_AT is assigned before COMMIT. The transaction is
    " intentionally paused below so that another session can
    " advance the timestamp-delta pointer before this change
    " becomes visible.
    "------------------------------------------------------------

    UPDATE zdb_src_price
      SET price      = @c_price,
          changed_at = @lv_change_at
      WHERE product_id  = @c_product_id
        AND store_group = @c_store_group.

    IF sy-subrc <> 0.
      out->write(
        |UPDATE failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    out->write(
      |Pending UPDATE: { c_product_id }/{ c_store_group } -> { c_price }, |
      && |CHANGED_AT = { lv_change_at }|
    ).

   "------------------------------------------------------------
    " Manual debugging anchor.
    "
    " Pause here BEFORE COMMIT WORK.
    " At this point the UPDATE has been executed in this LUW
    " but is not yet visible to other sessions.
    "------------------------------------------------------------
    DATA(lv_debug_anchor) = abap_true.

    COMMIT WORK.

    out->write(
      |Delayed UPDATE committed: { c_product_id }/{ c_store_group }.|
    ).

  ENDMETHOD.

ENDCLASS.
