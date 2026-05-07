[08.05.2026 00:18] Nazar: -- =============================================
-- Project: Order Payment Settlement Procedure
-- Technologies: SQL Server, T-SQL
--
-- Concepts Used:
-- - Stored Procedures
-- - TRY...CATCH
-- - Explicit Transactions
-- - Output Parameters
-- - CTE / Aggregate Queries
-- - Set-Based Updates
-- - Audit Logging
-- =============================================

-- Description:
-- This procedure validates customer orders,
-- checks product availability,
-- processes payment,
-- updates inventory,
-- writes audit logs,
-- and returns processing results.


CREATE OR ALTER PROCEDURE dbo.usp_SettleOrderPayment
    @IdOrder INT,
    @PaymentAmount DECIMAL(10,2),
    @ProcessedBy NVARCHAR(80),

    @OrderTotal DECIMAL(10,2) OUTPUT,
    @FulfilledItems INT OUTPUT,
    @StatusMessage NVARCHAR(200) OUTPUT
AS
BEGIN

    SET NOCOUNT ON;

    -- =============================================
    -- Initial Output Values
    -- =============================================

    SET @OrderTotal = 0;
    SET @FulfilledItems = 0;
    SET @StatusMessage = 'Processing order';


    -- =============================================
    -- Validation: Payment Amount
    -- =============================================

    IF @PaymentAmount <= 0
    BEGIN
        SET @StatusMessage = 'Payment amount must be greater than zero';

        RETURN 1;
    END;


    -- =============================================
    -- Validation: Order Exists and Status
    -- =============================================

    IF NOT EXISTS
    (
        SELECT 1
        FROM Task1_SalesOrders
        WHERE IdOrder = @IdOrder
          AND Status = 'PendingPayment'
    )
    BEGIN
        SET @StatusMessage =
            'Order does not exist or is not waiting for payment';

        RETURN 1;
    END;


    -- =============================================
    -- Calculate Order Total
    -- =============================================

    ;WITH OrderTotalCTE AS
    (
        SELECT
            SUM(Quantity * UnitPriceAtOrder) AS TotalAmount
        FROM Task1_OrderItems
        WHERE IdOrder = @IdOrder
    )
    SELECT
        @OrderTotal = TotalAmount
    FROM OrderTotalCTE;


    -- =============================================
    -- Validation: Payment Covers Total
    -- =============================================

    IF @PaymentAmount < @OrderTotal
    BEGIN
        SET @StatusMessage =
            'Payment amount is lower than order total';

        RETURN 2;
    END;


    -- =============================================
    -- Validation: Stock and Product Availability
    -- =============================================

    IF EXISTS
    (
        SELECT 1
        FROM Task1_OrderItems oi
        INNER JOIN Task1_Products p
            ON oi.IdProduct = p.IdProduct
        WHERE oi.IdOrder = @IdOrder
          AND
          (
                p.IsDiscontinued = 1
                OR
                p.UnitsInStock < oi.Quantity
          )
    )
    BEGIN

        SET @StatusMessage =
            'One or more products are unavailable';

        -- Return unavailable items
        SELECT
            p.IdProduct,
            p.ProductName,
            p.UnitsInStock,
            oi.Quantity AS OrderedQuantity,
            p.IsDiscontinued
        FROM Task1_OrderItems oi
        INNER JOIN Task1_Products p
            ON oi.IdProduct = p.IdProduct
        WHERE oi.IdOrder = @IdOrder
          AND
          (
                p.IsDiscontinued = 1
                OR
                p.UnitsInStock < oi.Quantity
          );

        RETURN 3;
    END;


    -- =============================================
    -- Main Processing Block
    -- =============================================

    BEGIN TRY

        BEGIN TRANSACTION;


        -- =============================================
        -- Reduce Product Stock
        -- =============================================

        UPDATE p
        SET p.UnitsInStock =
            p.UnitsInStock - oi.Quantity
        FROM Task1_Products p
        INNER JOIN Task1_OrderItems oi
            ON p.
[08.05.2026 00:18] Nazar: IdProduct = oi.IdProduct
        WHERE oi.IdOrder = @IdOrder;


        -- =============================================
        -- Fulfill Order Items
        -- =============================================

        UPDATE Task1_OrderItems
        SET LineStatus = 'Fulfilled'
        WHERE IdOrder = @IdOrder;

        SET @FulfilledItems = @@ROWCOUNT;


        -- =============================================
        -- Update Sales Order
        -- =============================================

        UPDATE Task1_SalesOrders
        SET
            Status = 'Paid',
            PaidAmount = @PaymentAmount,
            PaidAt = GETDATE(),
            ProcessedBy = @ProcessedBy
        WHERE IdOrder = @IdOrder;


        -- =============================================
        -- Write Audit Entry
        -- =============================================

        INSERT INTO Task1_OrderAudit
        (
            IdOrder,
            AuditLevel,
            Message,
            CreatedAt,
            CreatedBy
        )
        VALUES
        (
            @IdOrder,
            'Info',
            'Order payment processed successfully',
            GETDATE(),
            @ProcessedBy
        );


        -- =============================================
        -- Success Message
        -- =============================================

        SET @StatusMessage =
            'Order processed successfully';


        COMMIT TRANSACTION;


        -- =============================================
        -- Final Result Set
        -- =============================================

        SELECT
            so.IdOrder,
            so.CustomerName,
            so.Status,
            @OrderTotal AS OrderTotal,
            @PaymentAmount AS PaymentAmount,
            @FulfilledItems AS FulfilledItems,
            so.PaidAt,
            so.ProcessedBy
        FROM Task1_SalesOrders so
        WHERE so.IdOrder = @IdOrder;


        RETURN 0;

    END TRY


    -- =============================================
    -- Error Handling
    -- =============================================

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;


        INSERT INTO Task1_OrderAudit
        (
            IdOrder,
            AuditLevel,
            Message,
            CreatedAt,
            CreatedBy
        )
        VALUES
        (
            @IdOrder,
            'Error',
            ERROR_MESSAGE(),
            GETDATE(),
            @ProcessedBy
        );


        SET @StatusMessage = ERROR_MESSAGE();

        RETURN 500;

    END CATCH

END;
GO


-- =============================================
-- Test Example: Successful Payment
-- =============================================

DECLARE
    @OrderTotal DECIMAL(10,2),
    @FulfilledItems INT,
    @StatusMessage NVARCHAR(200),
    @ReturnCode INT;

EXEC @ReturnCode =
    dbo.usp_SettleOrderPayment
        @IdOrder = 1001,
        @PaymentAmount = 218.00,
        @ProcessedBy = 'Admin',
        @OrderTotal = @OrderTotal OUTPUT,
        @FulfilledItems = @FulfilledItems OUTPUT,
        @StatusMessage = @StatusMessage OUTPUT;

SELECT
    @ReturnCode AS ReturnCode,
    @OrderTotal AS OrderTotal,
    @FulfilledItems AS FulfilledItems,
    @StatusMessage AS StatusMessage;
