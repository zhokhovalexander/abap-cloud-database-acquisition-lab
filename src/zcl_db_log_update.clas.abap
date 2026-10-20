CLASS zcl_db_log_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.


  CONSTANTS:
  c_product_id  TYPE zdb_src_price-product_id
    VALUE 'P1001',
  c_store_group TYPE zdb_src_price-store_group
    VALUE 'SOUTH',
  c_price       TYPE zdb_src_price-price
    VALUE '16.00',
  c_currency    TYPE zdb_src_price-currency
    VALUE 'EUR',
  c_operation   TYPE zdb_change_log-operation
    VALUE 'U'.

    DATA lv_client      TYPE zdb_event_count-client.
    DATA lv_source_name TYPE zdb_event_count-source_name.

    lv_client      = sy-mandt.
    lv_source_name = 'PRODUCT_PRICE_LOG'.

    "------------------------------------------------------------
    " 1. Get lock object
    "------------------------------------------------------------
    TRY.
        DATA(lo_lock) =
          cl_abap_lock_object_factory=>get_instance(
            iv_name = 'EZDBEVCOUNT'
          ).

      CATCH cx_abap_lock_failure INTO DATA(lx_factory).
        out->write(
          |Lock object initialization failed: { lx_factory->get_text( ) }|
        ).
        RETURN.
    ENDTRY.


    "------------------------------------------------------------
    " 2. Lock counter for this source
    "------------------------------------------------------------
    TRY.

        lo_lock->enqueue(
          it_parameter = VALUE #(
            ( name  = 'CLIENT'
              value = REF #( lv_client ) )
            ( name  = 'SOURCE_NAME'
              value = REF #( lv_source_name ) )
          )
        ).

      CATCH cx_abap_foreign_lock INTO DATA(lx_foreign).
        out->write(
          |Event counter is locked by another session: { lx_foreign->get_text( ) }|
        ).
        RETURN.

      CATCH cx_abap_lock_failure INTO DATA(lx_lock).
        out->write(
          |Event counter lock failed: { lx_lock->get_text( ) }|
        ).
        RETURN.

    ENDTRY.


    "------------------------------------------------------------
    " 3. Allocate next event sequence
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_event_count
      FIELDS last_event_seq
      WHERE source_name = @lv_source_name
      INTO @DATA(lv_last_event_seq).

    IF sy-subrc <> 0.

  ROLLBACK WORK.

  TRY.
      lo_lock->dequeue( ).
    CATCH cx_abap_lock_failure.
      " Nothing else to do in this error branch
  ENDTRY.

  out->write( 'Event counter not found.' ).
  RETURN.

ENDIF.

    DATA(lv_event_seq) = lv_last_event_seq + 1.
    DATA(lv_event_at)  = utclong_current( ).

    UPDATE zdb_event_count
      SET last_event_seq = @lv_event_seq
      WHERE source_name = @lv_source_name.

    IF sy-subrc <> 0.
        ROLLBACK WORK.

        TRY.
            lo_lock->dequeue( ).
        CATCH cx_abap_lock_failure.
        ENDTRY.

        out->write( 'Event counter update failed.' ).
        RETURN.

    ENDIF.


    "------------------------------------------------------------
    " 4. Apply business UPDATE
    "------------------------------------------------------------
    UPDATE zdb_src_price
         SET price      = @c_price,
           currency   = @c_currency,
           changed_at = @lv_event_at
         WHERE product_id  = @c_product_id
         AND store_group = @c_store_group.

    IF sy-subrc <> 0.
        ROLLBACK WORK.

    TRY.
      lo_lock->dequeue( ).
    CATCH cx_abap_lock_failure.
    ENDTRY.

    out->write( 'Source UPDATE failed.' ).
    RETURN.

    ENDIF.


    "------------------------------------------------------------
    " 5. Write U event
    "------------------------------------------------------------
    DATA(ls_event) = VALUE zdb_change_log(
      client      = lv_client
      source_name = lv_source_name
      event_seq   = lv_event_seq
      product_id  = c_product_id
      store_group = c_store_group
      operation   = c_operation
      price       = c_price
      currency    = c_currency
      event_at    = lv_event_at
        ).

    INSERT zdb_change_log FROM @ls_event.

    IF sy-subrc <> 0.
        ROLLBACK WORK.

    TRY.
      lo_lock->dequeue( ).
    CATCH cx_abap_lock_failure.
    ENDTRY.

    out->write( 'Change-log INSERT failed.' ).
     RETURN.

    ENDIF.


    "------------------------------------------------------------
" Manual debugging anchor
"
" At this point:
" - EZDBEVCOUNT is still locked
" - counter change is uncommitted
" - business UPDATE is uncommitted
" - change-log INSERT is uncommitted
"
" Do NOT move the DEQUEUE before COMMIT.
"------------------------------------------------------------
    DATA(lv_debug_anchor) = abap_true.


    "------------------------------------------------------------
    " 6. Commit atomically and release lock
    "------------------------------------------------------------
    COMMIT WORK.

    TRY.
        lo_lock->dequeue( ).
      CATCH cx_abap_lock_failure INTO DATA(lx_dequeue).
        out->write(
          |Commit succeeded, but lock release failed: { lx_dequeue->get_text( ) }|
        ).
        RETURN.
    ENDTRY.

   out->write(
     |Committed event { lv_event_seq }: |
     && |{ c_product_id }/{ c_store_group } UPDATE -> { c_price }.|
     ).

  ENDMETHOD.

ENDCLASS.
